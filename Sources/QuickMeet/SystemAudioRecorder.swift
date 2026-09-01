import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio

/// Captures what the Mac is *playing* — the other people in the call.
///
/// **Core Audio process taps, not ScreenCaptureKit.** Both can reach system audio, and
/// the difference is what macOS asks the user for. A tap needs only "System Audio
/// Recording"; ScreenCaptureKit needs Screen Recording, which grants an app the ability
/// to read every window on the display. A meeting recorder has no business holding that,
/// and a permission prompt that says "record your screen" for an app that only wants
/// audio is a prompt people are right to refuse.
///
/// The shape of it:
///
///   1. `AudioHardwareCreateProcessTap` makes a tap object out of a `CATapDescription`.
///   2. The tap is wrapped in a *private* aggregate device — private so it never shows up
///      in Sound settings or in anyone else's device picker.
///   3. An IOProc on that aggregate delivers the tapped audio like any other input.
///
/// Step 3 is why this ends up in the same shape as `MicRecorder`: both hand
/// `PCMStreamWriter` a mono buffer from a real-time callback.
///
/// ### The aggregate must be anchored to a real output device
///
/// A tap needs an aggregate device to be read through, and that aggregate needs a clock.
/// It is tempting to build it from the tap alone — no hardware device involved, nothing
/// that could disturb the user's headphones. **That does not work, and it fails silently.**
/// Measured: a tap-only aggregate is created with `status == noErr`, reports the tap's two
/// input channels when asked, accepts an IOProc, returns `noErr` from `AudioDeviceStart`,
/// and then never calls the IOProc at all. Zero frames — not silence, *nothing*. Every
/// check you would naturally write to validate it passes.
///
/// Anchoring the same tap to the default output device as the aggregate's main sub-device
/// delivers audio immediately (281,600 frames in a three-second test).
///
/// So the anchored form is the primary path and the tap-only form is a last resort, which
/// is the opposite of what seems safer. Two things make that acceptable:
///
///  * On current macOS a Bluetooth headset is presented as **two** devices, and the output
///    half has zero input channels. Putting it in an aggregate therefore never opens its
///    microphone, which is what actually triggers the A2DP→HFP collapse. Verified on CMF
///    Buds 2: `2/0` channels on the output device.
///  * `verifyIOStarted` now checks that frames are genuinely arriving shortly after start,
///    so if any of this stops holding, it reports a failure instead of recording an hour
///    of nothing.
final class SystemAudioRecorder {
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: PCMStreamWriter?

    /// Allocated once, at start. The IOProc must not allocate.
    private var monoBuffer: AVAudioPCMBuffer?
    private var tapChannels = 0
    /// Index of the first tap channel in the aggregate's input buffer list. Non-zero only
    /// on the fallback path, when a sub-device contributes input channels of its own.
    private var channelOffset = 0

    private(set) var isRecording = false
    private(set) var sourceLabel = "—"

    /// Whether the IOProc has actually been called. Written on the IO thread, read from
    /// the main thread a second later — a monotonic flag, so the only way to read it wrong
    /// is to see `false` a moment before it becomes true, which is exactly what the delay
    /// in `verifyIOStarted` is for.
    private var didReceiveFrames = false

    /// True once audio has genuinely started arriving.
    var isReceivingAudio: Bool { didReceiveFrames }

    /// Host time of the previous callback, for gap detection. Mach absolute time is wall
    /// clock, which is the point: the device's own sample clock stops when the device
    /// idles, so it cannot be used to notice that time has passed.
    private var lastHostSeconds: Double = 0
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    private static func hostSeconds(_ hostTime: UInt64) -> Double {
        Double(hostTime) * timebase.numer / timebase.denom / 1e9
    }

    /// Output devices to try as the aggregate's clock, best first.
    private var anchors: [String] = []
    private var anchorIndex = 0
    private var currentSource: SystemAudioSource = .allApps
    private var outputURL: URL?

    var onLevel: ((Float) -> Void)?

    /// Kept past `stop()` — see the note in `MicRecorder`. Reading these through to the
    /// writer meant `wasSilentThroughout` was always true once stopped, which is precisely
    /// when it gets asked.
    private var finalPeak: Float = 0
    private var finalDuration: TimeInterval = 0

    var peakLevel: Float { writer?.peakLevel ?? finalPeak }
    var duration: TimeInterval { writer?.duration ?? finalDuration }

    enum TapError: LocalizedError {
        case permissionDenied(OSStatus)
        case couldNotCreateTap(OSStatus)
        case couldNotCreateAggregate(OSStatus)
        case couldNotStart(String, OSStatus)
        case noTapFormat
        case appNotRunning(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "QuickMeet isn't allowed to record system audio yet."
            case let .couldNotCreateTap(status):
                return "The system audio tap could not be created (status \(status))."
            case let .couldNotCreateAggregate(status):
                return "The system audio device could not be created (status \(status))."
            case let .couldNotStart(step, status):
                return "System audio capture could not start (\(step), status \(status))."
            case .noTapFormat:
                return "The system audio tap reported no format."
            case let .appNotRunning(name):
                return "\(name) isn't running, so there is no audio to capture from it."
            }
        }
    }

    // MARK: - Lifecycle

    func start(source: SystemAudioSource, to url: URL) throws {
        stopIO()
        didReceiveFrames = false
        finalPeak = 0
        finalDuration = 0
        // The gap clock starts *now*, not at the first callback.
        //
        // A device that is idle when recording begins delivers nothing until something
        // plays — and it does recover on its own when that happens, measured. But the
        // silence before the first frame is real time that the microphone stream is
        // recording through. Anchoring the clock here means that leading silence gets
        // padded like any other gap, so the two streams start aligned instead of the
        // system stream beginning wherever the far end happened to first make a sound.
        lastHostSeconds = Self.hostSeconds(mach_absolute_time())
        currentSource = source
        sourceLabel = source.label
        anchors = Self.anchorCandidates()
        anchorIndex = 0
        outputURL = url

        try openCapture()
        isRecording = true
    }

    /// Builds the tap, the aggregate and the IOProc, and starts IO.
    ///
    /// Separate from `start` so `reattach()` can rebuild all three against a different
    /// clock device without disturbing the writer or anything already recorded into it.
    private func openCapture() throws {
        guard let url = outputURL else { throw TapError.noTapFormat }

        let description = try Self.makeDescription(for: currentSource)

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            // A refused permission and a broken description are indistinguishable here —
            // the API returns the same unhelpful status either way, and there is no public
            // call to ask which it was. The caller decides how to phrase it based on
            // whether the user has been asked before.
            Diagnostics.recordError("AudioHardwareCreateProcessTap failed status=\(tapStatus)")
            throw TapError.permissionDenied(tapStatus)
        }
        tapID = tap

        var failed = true
        defer { if failed { destroyTap() } }

        guard let tapFormat = Self.format(ofTap: tap) else { throw TapError.noTapFormat }
        tapChannels = Int(tapFormat.channelCount)
        Diagnostics.log(
            "tap created source=\(currentSource.label) rate=\(Int(tapFormat.sampleRate))Hz ch=\(tapChannels)"
        )

        let (aggregate, offset) = try makeAggregate(
            tapUID: description.uuid.uuidString, tapChannels: tapChannels
        )
        aggregateID = aggregate
        channelOffset = offset

        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let monoBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: 8192)
        else { throw TapError.noTapFormat }
        self.monoBuffer = monoBuffer

        // Created once and kept across re-anchoring — the file must survive a change of
        // clock device with everything recorded so far still in it.
        if writer == nil {
            let writer = try PCMStreamWriter(url: url, sourceFormat: captureFormat, maxFrames: 8192)
            writer.onLevel = { [weak self] level in self?.onLevel?(level) }
            self.writer = writer
        }

        var proc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &proc, aggregate, nil
        ) { [weak self] _, inputData, inputTime, _, _ in
            self?.capture(inputData, at: inputTime)
        }
        guard procStatus == noErr, let proc else {
            throw TapError.couldNotStart("create IOProc", procStatus)
        }
        procID = proc

        let startStatus = AudioDeviceStart(aggregate, proc)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, proc)
            procID = nil
            throw TapError.couldNotStart("start device", startStatus)
        }

        failed = false
    }

    /// Output devices to anchor the aggregate's clock to, best first.
    ///
    /// Only a fallback for aggregate *creation* — if the default output cannot form one,
    /// another output device will. It is deliberately not a fallback for "no frames
    /// arrived": no device clocks while idle, so switching anchors there fixes nothing and
    /// only churns the audio graph mid-meeting.
    private static func anchorCandidates() -> [String] {
        var candidates: [String] = []
        if let id = AudioDevices.defaultOutputDeviceID, let uid = AudioDevices.uid(forDeviceID: id) {
            candidates.append(uid)
        }
        let others = AudioDevices.outputDeviceUIDs().filter { !candidates.contains($0) }
        // Non-Bluetooth first among the rest, for the same clock reason.
        candidates.append(contentsOf: others.filter { !AudioDevices.isBluetooth(uid: $0) })
        candidates.append(contentsOf: others.filter { AudioDevices.isBluetooth(uid: $0) })
        return candidates
    }

    /// Checks that frames are really arriving, a moment after starting.
    ///
    /// This exists because every failure mode of a process tap is silent. A tap-only
    /// aggregate creates, reports channels, accepts an IOProc and starts — all `noErr` —
    /// and then never calls back. Without this the app would show a level meter at zero
    /// for an hour and produce a meeting with only one side of the conversation in it,
    /// and nothing in the log would say why.
    ///
    /// A hint about the capture, or nil when there is nothing worth saying.
    ///
    /// **Receiving no frames is not a failure.** Measured, on a fresh process per trial:
    /// no output device clocks while nothing is playing — not the Bluetooth default, not
    /// the built-in speakers. Core Audio idles the device, the aggregate stops, and the
    /// IOProc simply is not called. As soon as anything plays, any anchor runs.
    ///
    /// An earlier version treated that silence as a broken tap, warned the user that
    /// system audio was not being delivered, and rebuilt the aggregate against a different
    /// clock device to "fix" it. Both were wrong: nothing was broken, and a first
    /// measurement suggesting the built-in output was immune had simply been contaminated
    /// by the trial before it, which had played a sound.
    ///
    /// What *is* worth reporting is the opposite shape: the device is running — so
    /// something is genuinely playing — and every sample of it is zero. That is what a
    /// refused System Audio Recording permission looks like from inside the process, since
    /// macOS hands over silence rather than an error.
    func healthHint() -> String? {
        guard isRecording, didReceiveFrames else { return nil }
        guard peakLevel < AudioChunker.silenceThreshold else { return nil }
        return "Audio is playing but nothing is reaching QuickMeet. Check Privacy & Security → "
            + "Screen & System Audio Recording."
    }

    /// After the fact: frames arrived, but every one of them was silent.
    ///
    /// That is what a refused System Audio Recording permission looks like — macOS runs
    /// the IO cycle and hands over zeros rather than failing the call, so it is
    /// indistinguishable from a genuinely quiet meeting until the end.
    var wasSilentThroughout: Bool {
        didReceiveFrames && peakLevel < AudioChunker.silenceThreshold
    }

    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        stopIO()

        // Read the writer's totals before letting go of it.
        finalPeak = writer?.peakLevel ?? 0
        finalDuration = writer?.duration ?? 0

        let url = writer?.close()
        writer = nil
        return url
    }

    private func stopIO() {
        teardownIO()
        monoBuffer = nil
    }

    /// Tears down tap, aggregate and IOProc, leaving the writer alone.
    private func teardownIO() {
        if aggregateID != AudioDeviceID(kAudioObjectUnknown), let procID {
            // Synchronous, like AudioOutputUnitStop: the IO thread has finished by the
            // time this returns, so nothing can still be writing into the buffers below.
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil

        if aggregateID != AudioDeviceID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
        }
        destroyTap()
    }

    private func destroyTap() {
        guard tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Capture

    /// Real-time IO thread. Averages the tap's channels into the pre-allocated mono buffer
    /// and hands it to the writer, which does no disk I/O here either.
    ///
    /// **The tap delivers one interleaved buffer, not one buffer per channel.** Measured:
    /// `mNumberBuffers = 1`, `mNumberChannels = 2`, `mBytesPerFrame = 8`. An earlier
    /// version of this method selected only buffers with `mNumberChannels == 1`, which
    /// matched nothing, discarded every frame, and presented as "system audio isn't being
    /// delivered" with the permission correctly granted and the tap running fine.
    ///
    /// So this walks channels globally rather than assuming a layout: each buffer
    /// contributes `mNumberChannels` consecutive channels to one running index, and the
    /// window `[channelOffset, channelOffset + tapChannels)` is mixed down. That is correct
    /// for interleaved, for one-buffer-per-channel, and for the mixture of the two an
    /// aggregate produces when a sub-device contributes input streams of its own.
    private func capture(
        _ inputData: UnsafePointer<AudioBufferList>,
        at inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let monoBuffer, let destination = monoBuffer.floatChannelData?[0] else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard buffers.count > 0 else { return }

        let wanted = max(tapChannels, 1)
        let firstChannel = channelOffset
        let lastChannel = channelOffset + wanted

        // Frame count comes from the first buffer carrying audio; every buffer in one
        // callback covers the same span of time.
        var frames = 0
        for buffer in buffers where buffer.mData != nil && buffer.mNumberChannels > 0 {
            frames = Int(buffer.mDataByteSize)
                / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels))
            break
        }
        guard frames > 0, frames <= Int(monoBuffer.frameCapacity) else { return }

        for frame in 0..<frames { destination[frame] = 0 }

        var globalChannel = 0
        var mixed = 0

        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            defer { globalChannel += channels }
            guard channels > 0, let raw = buffer.mData else { continue }

            // Skip a buffer that lies entirely outside the tap's channel window — on the
            // anchored path the head can belong to the anchor device, and its microphone
            // is the last thing that should reach a recording of other people.
            guard globalChannel + channels > firstChannel, globalChannel < lastChannel else { continue }

            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard available >= frames else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)

            for channel in 0..<channels {
                let global = globalChannel + channel
                guard global >= firstChannel, global < lastChannel else { continue }
                mixed += 1
                if channels == 1 {
                    for frame in 0..<frames { destination[frame] += samples[frame] }
                } else {
                    // Interleaved: channel `c` of frame `f` sits at `f * channels + c`.
                    for frame in 0..<frames {
                        destination[frame] += samples[frame * channels + channel]
                    }
                }
            }
        }

        guard mixed > 0 else { return }
        if mixed > 1 {
            let scale = 1 / Float(mixed)
            for frame in 0..<frames { destination[frame] *= scale }
        }

        // Wall-clock gap since the previous callback, minus the audio this one carries.
        // Anything left over is time the device spent not running, and the file has to
        // account for it or every later timestamp slides earlier.
        let stamp = inputTime.pointee
        if stamp.mFlags.contains(.hostTimeValid) {
            let now = Self.hostSeconds(stamp.mHostTime)
            if lastHostSeconds > 0, now > lastHostSeconds {
                let elapsed = now - lastHostSeconds
                let carried = Double(frames) / monoBuffer.format.sampleRate
                let gap = elapsed - carried
                // A whole buffer's slack before it counts as a gap: scheduling jitter
                // between callbacks is normal and must not accumulate into drift.
                if gap > carried + 0.05 {
                    writer?.padSilence(seconds: min(gap, 300))
                }
            }
            lastHostSeconds = now
        }

        didReceiveFrames = true
        monoBuffer.frameLength = AVAudioFrameCount(frames)
        writer?.append(monoBuffer)
    }

    /// Creates and immediately destroys a tap, to find out whether we are allowed to.
    ///
    /// macOS exposes no public way to read the System Audio Recording permission, and no
    /// way to request it either — the first `AudioHardwareCreateProcessTap` is both the
    /// request and the answer. So the honest thing Settings can offer is a button that
    /// does exactly that and reports what happened, rather than a status light that is
    /// guessing.
    static func probe() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "QuickMeet permission check"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        defer {
            if tap != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tap) }
        }
        Diagnostics.log("system audio probe status=\(status)")
        return status == noErr && tap != AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Tap description

    private static func makeDescription(for source: SystemAudioSource) throws -> CATapDescription {
        let description: CATapDescription

        switch source {
        case .allApps:
            // Excluding ourselves is belt-and-braces — QuickMeet plays only the short
            // start and stop cues — but a tap that recorded the app's own confirmation
            // sound back into the meeting would be a silly thing to debug later.
            let ourselves = processObjectID(for: ProcessInfo.processInfo.processIdentifier)
            description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: ourselves.map { [$0] } ?? []
            )
        case let .app(bundleID, name):
            let pids = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID)
                .map { $0.processIdentifier }
            let objects = pids.compactMap(processObjectID)
            guard !objects.isEmpty else { throw TapError.appNotRunning(name) }
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }

        description.name = "QuickMeet"
        description.uuid = UUID()
        // Private: the tap belongs to this process and never appears in anyone else's
        // device list.
        description.isPrivate = true
        // Unmuted matters — a muted tap records the audio but stops the user hearing it,
        // which in a meeting means the tap silently deafens you to the people you are
        // talking to.
        description.muteBehavior = .unmuted
        return description
    }

    /// CoreAudio addresses processes by its own object ID, not by pid, so a pid has to be
    /// translated before it can go into a tap description.
    private static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &qualifier,
            &size,
            &object
        )
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return object
    }

    private static func format(ofTap tap: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr,
              asbd.mSampleRate > 0
        else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    // MARK: - Aggregate device

    /// Returns the aggregate and the index of its first tap-owned input channel.
    ///
    /// Order matters and is the opposite of what looks safest — see the note on the type.
    /// The anchored aggregate is the only form measured to actually deliver frames.
    private func makeAggregate(tapUID: String, tapChannels: Int) throws -> (AudioDeviceID, Int) {
        // The tap captures what each process plays, not what one device renders, so the
        // choice of anchor changes only the clock — never what ends up in the recording.
        for anchor in Array(anchors[min(anchorIndex, anchors.count)...]) {
            guard let device = Self.createAggregate(tapUID: tapUID, anchorUID: anchor) else { continue }

            // Channels the anchor contributes come first; the tap's are appended. Only the
            // tail belongs to us — the head could be the anchor's own microphone, which is
            // the last thing that should end up in a recording of other people. On current
            // macOS an output device is input-less and this is zero, but an aggregate or a
            // USB interface used as the default output is not.
            let inputs = AudioDevices.channelCount(device, scope: kAudioObjectPropertyScopeInput)
            let offset = max(0, inputs - tapChannels)
            Diagnostics.log(
                "aggregate: anchored to \(anchor), inputChannels=\(inputs), "
                + "tapChannels=\(tapChannels), offset=\(offset)"
            )
            return (device, offset)
        }

        // Last resort. Known to create cleanly and then never run its IOProc, so this is
        // only worth trying when there is no output device at all to anchor to — and
        // `verifyIOStarted` will catch it if it behaves the way it usually does.
        if let device = Self.createAggregate(tapUID: tapUID, anchorUID: nil) {
            Diagnostics.log("aggregate: no anchor available, falling back to a tap-only device")
            return (device, 0)
        }

        throw TapError.couldNotCreateAggregate(OSStatus(kAudioHardwareUnspecifiedError))
    }

    private static func createAggregate(tapUID: String, anchorUID: String?) -> AudioDeviceID? {
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "QuickMeet System Audio",
            kAudioAggregateDeviceUIDKey: "com.quickmeet.QuickMeet.tap.\(UUID().uuidString)",
            // Private: no entry in Sound settings, and no stray device left behind for the
            // user to wonder about if the app is force-quit.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID,
                ]
            ],
        ]

        if let anchorUID {
            description[kAudioAggregateDeviceMainSubDeviceKey] = anchorUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: anchorUID]]
        } else {
            description[kAudioAggregateDeviceSubDeviceListKey] = [[String: Any]]()
        }

        var device = AudioDeviceID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard status == noErr, device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }
}
