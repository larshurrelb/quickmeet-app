import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures the microphone — your half of the meeting.
///
/// **Capture goes through a raw AUHAL, not `AVAudioEngine`.** That is not a style
/// preference, and it is the single most expensive thing QuickTalk learned:
/// `AVAudioEngine.start()` silently rebinds its input to a system
/// `CADefaultDeviceAggregate` wrapping the *default* input device, discarding any device
/// set on the input node beforehand. The set succeeds, reads back correctly, survives
/// `prepare()`, and is thrown away by `start()`. Two consequences followed:
///
///   * the microphone picker did nothing; every recording came from the system default;
///   * with Bluetooth headphones as that default, opening their microphone flipped them
///     from A2DP to HFP, collapsing playback to mono at 16 kHz.
///
/// An AUHAL takes `kAudioOutputUnitProperty_CurrentDevice` *before* `AudioUnitInitialize`
/// and keeps it, so nothing but the chosen device is ever opened.
///
/// The second half of that lesson is `resolve(uid:)`: "system default" is turned into a
/// concrete `AudioDeviceID` here rather than left to CoreAudio, because asking CoreAudio
/// for "the default device" is what builds the aggregate that drags the Bluetooth
/// microphone in.
final class MicRecorder {
    /// The input bus of an AUHAL. Bus 0 is output to the device, which we disable.
    private static let inputBus: AudioUnitElement = 1
    private static let maxFramesPerSlice: AVAudioFrameCount = 4096

    private var unit: AudioUnit?
    private var writer: PCMStreamWriter?
    private var captureBuffer: AVAudioPCMBuffer?

    private(set) var isRecording = false
    private(set) var deviceName = "—"

    var onLevel: ((Float) -> Void)?

    /// Kept past `stop()`.
    ///
    /// These used to read straight through to the writer — `writer?.peakLevel ?? 0` — and
    /// `stop()` releases the writer, so every caller that asked *after* stopping got zero.
    /// That is the only moment anyone wants to ask. It made a 25-second recording with a
    /// healthy 0.21 peak report as silence, which then discarded the whole stream.
    private var finalPeak: Float = 0
    private var finalDuration: TimeInterval = 0

    var peakLevel: Float { writer?.peakLevel ?? finalPeak }
    var duration: TimeInterval { writer?.duration ?? finalDuration }

    enum RecorderError: LocalizedError {
        case noInputDevice
        case couldNotConfigure(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No microphone is available."
            case let .couldNotConfigure(step, status):
                return "The microphone could not be opened (\(step), status \(status))."
            }
        }
    }

    private struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// `deviceUID` empty means follow the system default.
    func start(deviceUID: String, to url: URL) throws {
        stopUnit()

        finalPeak = 0
        finalDuration = 0

        let device = try Self.resolve(uid: deviceUID)
        deviceName = device.name

        let unit = try Self.makeInputUnit(device: device.id)
        var failed = true
        defer { if failed { AudioComponentInstanceDispose(unit) } }

        // The hardware's own format, read after the device is bound — a different device
        // can mean a different sample rate and channel count.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let readStatus = AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, Self.inputBus, &hardware, &size
        )
        guard readStatus == noErr, hardware.mSampleRate > 0 else {
            throw RecorderError.couldNotConfigure("read hardware format", readStatus)
        }

        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardware.mSampleRate,
            channels: AVAudioChannelCount(max(1, hardware.mChannelsPerFrame)),
            interleaved: false
        ) else { throw RecorderError.noInputDevice }

        var client = clientFormat.streamDescription.pointee
        let formatStatus = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, Self.inputBus,
            &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard formatStatus == noErr else {
            throw RecorderError.couldNotConfigure("set client format", formatStatus)
        }

        var maxFrames = Self.maxFramesPerSlice
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            &maxFrames, UInt32(MemoryLayout<AVAudioFrameCount>.size)
        )

        let writer = try PCMStreamWriter(url: url, sourceFormat: clientFormat, maxFrames: maxFrames)
        writer.onLevel = { [weak self] level in self?.onLevel?(level) }

        guard let captureBuffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: maxFrames) else {
            throw RecorderError.noInputDevice
        }

        var callback = AURenderCallbackStruct(
            inputProc: Self.render,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let callbackStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard callbackStatus == noErr else {
            throw RecorderError.couldNotConfigure("set input callback", callbackStatus)
        }

        let initStatus = AudioUnitInitialize(unit)
        guard initStatus == noErr else {
            throw RecorderError.couldNotConfigure("initialize", initStatus)
        }

        // Everything the callback touches must be in place before IO starts.
        self.unit = unit
        self.writer = writer
        self.captureBuffer = captureBuffer

        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            AudioUnitUninitialize(unit)
            self.unit = nil
            self.writer = nil
            self.captureBuffer = nil
            writer.close()
            throw RecorderError.couldNotConfigure("start", startStatus)
        }

        failed = false
        isRecording = true
        // The device *name* is logged, not just the stored UID. When the picker was
        // silently ignored in QuickTalk, the log said "system default" either way and hid
        // the bug for months.
        Diagnostics.log(
            "mic started device=\(device.name) [\(device.uid)] "
            + "rate=\(Int(hardware.mSampleRate))Hz ch=\(Int(hardware.mChannelsPerFrame))"
        )
    }

    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        stopUnit()

        // Read the writer's totals before letting go of it.
        finalPeak = writer?.peakLevel ?? 0
        finalDuration = writer?.duration ?? 0

        let url = writer?.close()
        writer = nil
        return url
    }

    private func stopUnit() {
        if let unit {
            // Synchronous: it does not return until the IO thread has stopped, so no
            // render callback can still be running when the buffers go away below.
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        captureBuffer = nil
    }

    // MARK: - Device and unit setup

    private static func resolve(uid: String) throws -> Device {
        if !uid.isEmpty {
            if let id = AudioDevices.deviceID(forUID: uid) {
                return Device(id: id, uid: uid, name: AudioDevices.name(forDeviceID: id) ?? uid)
            }
            Diagnostics.log("microphone \(uid) isn't connected — falling back to the system default")
        }

        guard let id = AudioDevices.defaultInputDeviceID else { throw RecorderError.noInputDevice }
        return Device(
            id: id,
            uid: AudioDevices.uid(forDeviceID: id) ?? "",
            name: AudioDevices.name(forDeviceID: id) ?? "system default"
        )
    }

    private static func makeInputUnit(device: AudioDeviceID) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RecorderError.noInputDevice
        }

        var instance: AudioUnit?
        let newStatus = AudioComponentInstanceNew(component, &instance)
        guard newStatus == noErr, let unit = instance else {
            throw RecorderError.couldNotConfigure("instantiate AUHAL", newStatus)
        }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)

        let enableStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, &enable, flagSize
        )
        let disableStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, flagSize
        )
        guard enableStatus == noErr, disableStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            throw RecorderError.couldNotConfigure(
                "enable input", enableStatus != noErr ? enableStatus : disableStatus
            )
        }

        // The whole point of using an AUHAL: this is set before AudioUnitInitialize, and
        // unlike AVAudioEngine's input node it survives starting the unit.
        var id = device
        let deviceStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            throw RecorderError.couldNotConfigure("bind device", deviceStatus)
        }

        return unit
    }

    // MARK: - Capture

    private static let render: AURenderCallback = { refcon, flags, timestamp, bus, frames, _ in
        let recorder = Unmanaged<MicRecorder>.fromOpaque(refcon).takeUnretainedValue()
        return recorder.capture(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
    }

    private func capture(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit, let buffer = captureBuffer, frames <= buffer.frameCapacity else { return noErr }

        // Setting frameLength also fixes up the buffer list's mDataByteSize, which is what
        // AudioUnitRender checks against the frame count it was asked for.
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }

        writer?.append(buffer)
        return noErr
    }

    static func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    static var hasMicrophoneAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
