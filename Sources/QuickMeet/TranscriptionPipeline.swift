import Foundation

/// Everything that happens between "stop" and a finished meeting.
///
/// Ordered so that the most valuable thing is secured first. The transcript is saved as
/// soon as it exists, before the notes pass runs — if summarising fails, or the app is
/// quit while it is running, the meeting still has its transcript. Notes can be produced
/// again from the transcript at any time; a transcript cannot be produced again once the
/// audio is gone.
@MainActor
final class TranscriptionPipeline {
    private let store: MeetingStore
    private let settings: AppSettings

    /// Meetings currently being processed, so a second Retry cannot start a duplicate run.
    private var running = Set<UUID>()

    /// Chunks finished, per run, for the progress line. Keyed by meeting rather than held
    /// as one field: `running` is a set, so two meetings retried at once would otherwise
    /// share a counter and report each other's progress. Lives on the pipeline so the
    /// counter has one owner on the main actor instead of being mutated from the
    /// transcription task.
    private var completedChunks: [UUID: Int] = [:]

    init(store: MeetingStore, settings: AppSettings = .shared) {
        self.store = store
        self.settings = settings
    }

    var isBusy: Bool { !running.isEmpty }

    func process(_ id: UUID) {
        guard !running.contains(id) else { return }
        running.insert(id)

        Task { [weak self] in
            await self?.run(id)
            self?.running.remove(id)
            self?.completedChunks[id] = nil
        }
    }

    // MARK: - The run

    private func run(_ id: UUID) async {
        guard let meeting = store.meeting(id) else { return }

        let key = settings.apiKey
        guard !key.isEmpty else {
            fail(id, "No API key set. Open QuickMeet Settings and paste your Gemini key.")
            return
        }

        store.update(id) {
            $0.status = .processing
            $0.errorMessage = nil
            $0.progress = "Preparing audio…"
        }

        let directory = store.directory(for: id)
        let chunkDirectory = directory.appendingPathComponent("chunks")
        let micURL = store.micURL(for: id)
        let systemURL = store.systemURL(for: id)

        // A crash mid-meeting leaves a WAV whose header never got its lengths. Patch
        // before measuring anything, or the whole recording reads as zero seconds long.
        PCMStreamWriter.repair(at: micURL)
        PCMStreamWriter.repair(at: systemURL)

        let transcriber = GeminiTranscriber(apiKey: key)

        do {
            let micChunks = try AudioChunker.chunk(wav: micURL, into: chunkDirectory)

            // Gate on the audio, never on the flag.
            //
            // This used to read `meeting.systemAudioCaptured ? chunk(…) : []`, and that
            // flag is set from a health check and a peak reading — advisory metadata. When
            // the peak was misread as zero, a perfectly good 23-second recording of the
            // other participants was silently skipped and the user got a transcript with
            // only their own voice in it.
            //
            // A file with audio in it gets transcribed. Whether each chunk is worth a
            // request is decided per chunk from its actual samples, which is the only test
            // that looks at the recording rather than at something we believed about it.
            let systemDuration = AudioChunker.duration(ofWAV: systemURL)
            let systemChunks = systemDuration > 0.5
                ? try AudioChunker.chunk(wav: systemURL, into: chunkDirectory)
                : []
            if systemDuration <= 0.5 {
                Diagnostics.log("no system audio to transcribe (\(String(format: "%.2f", systemDuration))s)")
            }

            let total = micChunks.filter { !$0.isSilent }.count
                + systemChunks.filter { !$0.isSilent }.count
            guard total > 0 else {
                fail(id, "Nothing was recorded — both streams are silent. Check the microphone in Settings.")
                return
            }

            completedChunks[id] = 0
            // Reports the chunk being worked on, not the one just finished — "Transcribing
            // 3 of 5" while the third is in flight reads better than a counter that sits on
            // 2 for twenty minutes.
            let bump: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.completedChunks[id, default: 0] += 1
                    let done = min((self.completedChunks[id] ?? 0) + 1, total)
                    self.store.update(id) { $0.progress = "Transcribing \(done) of \(total)…" }
                }
            }
            store.update(id) { $0.progress = "Transcribing 1 of \(total)…" }

            // The two streams are independent requests, so run them concurrently — a
            // 40-minute meeting is four uploads, and doing them in series doubles the wait
            // for no reason.
            async let micWords = Self.transcribeStream(
                micChunks, using: transcriber, diarize: false, onChunk: bump
            )
            async let systemWords = Self.transcribeStream(
                systemChunks, using: transcriber, diarize: true, onChunk: bump
            )

            let micTurns = TranscriptBuilder.turns(
                from: try await micWords, fallbackSpeaker: SpeakerID.you.storedValue
            )
            let systemTurns = TranscriptBuilder.turns(
                from: try await systemWords, fallbackSpeaker: "spk_1"
            )
            let turns = TranscriptBuilder.merge(mic: micTurns, system: systemTurns)

            guard !turns.isEmpty else {
                fail(id, "No speech was found in the recording.")
                return
            }

            // Save the transcript before the notes pass. This is the point of no return
            // worth protecting.
            store.update(id) {
                $0.turns = turns
                $0.progress = "Writing notes…"
            }
            store.clearChunks(for: id)
            Diagnostics.log("meeting \(id) transcript: \(turns.count) turns, \(Set(turns.map(\.speaker)).count) speakers")

            let notes = await GeminiNotes(apiKey: key)
                .notes(for: store.meeting(id) ?? meeting, language: settings.notesLanguage)

            let heardOthers = turns.contains { $0.speaker != SpeakerID.you.storedValue }
            store.update(id) {
                $0.notes = notes
                $0.status = .ready
                $0.progress = ""
                if $0.title.isEmpty, let suggested = notes?.suggestedTitle, !suggested.isEmpty {
                    $0.title = suggested
                }
                // Now that the transcript exists, it is the authority on whether the other
                // side was captured — not the flag set during recording.
                if heardOthers {
                    $0.systemAudioCaptured = true
                    $0.systemAudioIssue = nil
                }
            }

            if settings.retention == .deleteAfterTranscript {
                store.discardAudio(for: id)
            }
            store.applyRetention()

        } catch {
            fail(id, error.localizedDescription)
        }
    }

    private func fail(_ id: UUID, _ message: String) {
        store.update(id) {
            $0.status = .failed
            $0.errorMessage = message
            $0.progress = ""
        }
        Diagnostics.recordError("meeting \(id) failed: \(message)")
    }

    // MARK: - One stream

    /// Chunks are transcribed **in order**, not concurrently.
    ///
    /// Speaker stitching compares each chunk against the transcript assembled so far, so
    /// chunk N+1 cannot be matched up until chunk N exists. Parallelising within a stream
    /// would save a little time and cost the ability to know that two chunks are talking
    /// about the same person.
    private static func transcribeStream(
        _ chunks: [AudioChunker.Chunk],
        using transcriber: GeminiTranscriber,
        diarize: Bool,
        onChunk: @escaping @Sendable () -> Void
    ) async throws -> [TranscribedWord] {
        var results: [TranscriptBuilder.ChunkResult] = []

        for chunk in chunks {
            if chunk.isSilent {
                results.append(
                    TranscriptBuilder.ChunkResult(
                        offset: chunk.offset, duration: chunk.duration, words: []
                    )
                )
                continue
            }

            let words = try await transcriber.transcribe(chunk: chunk.url, diarize: diarize)
            results.append(
                TranscriptBuilder.ChunkResult(
                    offset: chunk.offset, duration: chunk.duration, words: words
                )
            )
            onChunk()
        }

        return TranscriptBuilder.assemble(results)
    }
}
