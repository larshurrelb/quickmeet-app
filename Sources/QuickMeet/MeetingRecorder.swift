import AppKit
import Combine
import Foundation

/// Runs a meeting: both capture streams, the clock, and the meeting record they belong to.
///
/// The two streams are deliberately independent. Putting the microphone and the tap into
/// one aggregate device would need drift compensation between two unrelated clock domains,
/// and would fuse the thing this app most wants kept apart — which half of the audio is
/// the user. Two files, two clocks, both started within a few milliseconds of each other
/// and both timestamped by the model afterwards, is simpler and produces a better
/// transcript.
///
/// A failure to capture system audio is **not** a failure to record. The user is still
/// speaking, the microphone is still running, and stopping the whole meeting because the
/// tap did not come up would throw away the half that was working.
@MainActor
final class MeetingRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var meetingID: UUID?
    /// Set when the tap failed but the microphone is running, so the HUD can say so
    /// while the meeting continues.
    @Published private(set) var systemAudioWarning: String?

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private var timer: Timer?
    private var startedAt: Date?

    private let store: MeetingStore
    private let settings: AppSettings

    // `store` has no default because there is exactly one, owned by `AppDelegate` and
    // handed to everything that needs it — and a main-actor default argument could not be
    // evaluated here anyway, since default expressions are nonisolated.
    init(store: MeetingStore, settings: AppSettings = .shared) {
        self.store = store
        self.settings = settings

        mic.onLevel = { [weak self] level in self?.micLevel = level }
        system.onLevel = { [weak self] level in self?.systemLevel = level }
    }

    // MARK: - Start and stop

    @discardableResult
    func start(consent: ConsentRecord) throws -> UUID {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        var meeting = Meeting()
        meeting.consent = consent
        meeting.status = .recording
        meeting.systemAudioCaptured = settings.recordSystemAudio

        // The record is written *before* the first sample. If the app dies thirty seconds
        // in, the folder and its metadata already exist and the WAVs inside it can be
        // recovered — `MeetingStore.recover` is the other half of this.
        store.save(meeting)

        do {
            try mic.start(deviceUID: settings.microphoneUID, to: store.micURL(for: meeting.id))
        } catch {
            store.delete(meeting.id)
            throw error
        }
        meeting.micDeviceName = mic.deviceName

        systemAudioWarning = nil
        if settings.recordSystemAudio {
            do {
                try system.start(source: settings.systemAudioSource, to: store.systemURL(for: meeting.id))
                meeting.systemAudioLabel = system.sourceLabel
            } catch {
                // Keep going on the microphone alone. Half a meeting is worth far more
                // than a cancelled one, and the HUD says plainly what is missing.
                meeting.systemAudioCaptured = false
                meeting.systemAudioLabel = ""
                systemAudioWarning = error.localizedDescription
                Diagnostics.recordError("system audio unavailable, recording microphone only: \(error)")
            }
        }

        store.save(meeting)

        meetingID = meeting.id
        startedAt = Date()
        elapsed = 0
        isRecording = true
        startClock()

        if settings.playSound { NSSound(named: "Purr")?.play() }
        scheduleSystemAudioHealthCheck(for: meeting.id)
        Diagnostics.log(
            "meeting \(meeting.id) started mic=\(meeting.micDeviceName) "
            + "system=\(meeting.systemAudioCaptured ? meeting.systemAudioLabel : "off")"
        )
        return meeting.id
    }

    /// Stops capture and hands the meeting to the pipeline. Returns the meeting's id.
    @discardableResult
    func stop() -> UUID? {
        guard isRecording, let id = meetingID else { return nil }
        isRecording = false
        stopClock()

        let micURL = mic.stop()
        let systemURL = system.stop()
        let duration = max(elapsed, mic.duration)

        let micPeak = mic.peakLevel
        let systemPeak = system.peakLevel

        store.update(id) { meeting in
            meeting.duration = duration
            meeting.status = .processing
            meeting.progress = "Preparing audio…"
        }

        Diagnostics.log(
            "meeting \(id) stopped duration=\(Int(duration))s "
            + "micPeak=\(String(format: "%.4f", micPeak)) "
            + "systemPeak=\(String(format: "%.4f", systemPeak))"
        )

        // A peak near zero means capture failed, not the API. Say so now rather than
        // spending a request to be told there was no speech.
        if micURL != nil, micPeak < AudioChunker.silenceThreshold, systemPeak < AudioChunker.silenceThreshold {
            Diagnostics.recordError("both streams are silent — capture failed, not transcription")
        }

        // Frames arrived for the whole meeting and every one of them was zero. That is
        // what a refused System Audio Recording permission looks like from inside the
        // process — macOS runs the IO cycle and hands over silence rather than returning
        // an error — so it can only be diagnosed here, at the end.
        if systemURL != nil, settings.recordSystemAudio {
            if system.wasSilentThroughout {
                // Frames arrived and every one was zero: something was playing and none of
                // it reached us. That is a refused permission.
                Diagnostics.recordError(
                    "system audio delivered only silence — most likely the System Audio Recording permission"
                )
                store.update(id) {
                    $0.systemAudioCaptured = false
                    $0.systemAudioIssue =
                        "Audio was playing but none of it reached QuickMeet. Check Privacy & Security "
                        + "→ Screen & System Audio Recording, then use Settings → Check permission."
                }
            } else if !system.isReceivingAudio {
                // No frames at all for the whole meeting. Usually means nothing ever
                // played — an in-person conversation, or a call that never connected —
                // which is not an error, just worth saying so the empty half is explained.
                Diagnostics.log("system audio: no frames for the whole meeting — nothing was playing")
                store.update(id) {
                    $0.systemAudioCaptured = false
                    $0.systemAudioIssue =
                        "Nothing was playing through this Mac during the meeting, so there was no "
                        + "call audio to record."
                }
            }
        }

        if settings.playSound { NSSound(named: "Bottle")?.play() }

        meetingID = nil
        startedAt = nil
        micLevel = 0
        systemLevel = 0
        systemAudioWarning = nil
        return id
    }

    // MARK: - Health

    /// A single late check for the one condition worth surfacing mid-meeting.
    ///
    /// Deliberately *not* an early check for "are frames arriving". No output device
    /// clocks while nothing is playing, so for the first stretch of a meeting — before
    /// anyone on the far end speaks — no frames is the normal, correct state. Warning
    /// about it told users their system audio was broken when it was fine.
    ///
    /// What this waits for instead is audio that is demonstrably playing and arriving as
    /// pure silence, which is how a refused permission presents. Twenty seconds in, so a
    /// genuinely quiet opening does not trip it.
    private func scheduleSystemAudioHealthCheck(for id: UUID) {
        guard system.isRecording else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.isRecording, self.meetingID == id else { return }
            guard let hint = self.system.healthHint() else { return }
            self.systemAudioWarning = hint
        }
    }

    // MARK: - Clock

    private func startClock() {
        // A timer only while recording. Idle cost still matters: nothing ticks, polls or
        // holds an audio session between meetings.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
    }

    enum RecorderError: LocalizedError {
        case alreadyRecording
        var errorDescription: String? { "A meeting is already being recorded." }
    }
}
