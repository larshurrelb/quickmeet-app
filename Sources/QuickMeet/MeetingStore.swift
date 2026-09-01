import Foundation
import Combine

/// Meetings on disk, one folder each.
///
/// A folder per meeting rather than one database: the audio has to live somewhere anyway,
/// and keeping `meeting.json` next to `mic.wav` and `system.wav` means deleting a meeting
/// is `removeItem` on one directory with nothing left behind. For an app whose files are
/// recordings of other people, "delete really deletes" is worth more than query speed.
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published private(set) var meetings: [Meeting] = []

    /// The folder every meeting lives in, one subfolder each.
    let root: URL

    init() {
        root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickMeet/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Paths

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func micURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("mic.wav") }
    func systemURL(for id: UUID) -> URL { directory(for: id).appendingPathComponent("system.wav") }
    private func metadataURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("meeting.json")
    }

    // MARK: - Loading

    private func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [Meeting] = []
        for folder in folders {
            let url = folder.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: url),
                  var meeting = try? decoder.decode(Meeting.self, from: data)
            else { continue }

            // A meeting still marked `recording` means the app died mid-meeting. The audio
            // is on disk and is worth rescuing — the WAV writer patches its own header on
            // demand for exactly this — so recover it as something the user can retry
            // rather than quietly dropping an hour of a conversation.
            if meeting.status == .recording || meeting.status == .processing {
                recover(&meeting)
            }
            loaded.append(meeting)
        }

        meetings = loaded.sorted { $0.startedAt > $1.startedAt }
        applyRetention()
    }

    private func recover(_ meeting: inout Meeting) {
        let mic = micURL(for: meeting.id)
        let system = systemURL(for: meeting.id)
        PCMStreamWriter.repair(at: mic)
        PCMStreamWriter.repair(at: system)

        let recovered = max(
            AudioChunker.duration(ofWAV: mic),
            AudioChunker.duration(ofWAV: system)
        )
        meeting.duration = max(meeting.duration, recovered)
        meeting.status = .failed
        meeting.errorMessage = meeting.turns.isEmpty
            ? "QuickMeet quit before this meeting was transcribed. The audio was recovered — use Retry."
            : "Transcription was interrupted."
        Diagnostics.log("recovered interrupted meeting \(meeting.id) duration=\(Int(recovered))s")
        save(meeting)
    }

    // MARK: - Mutation

    func save(_ meeting: Meeting) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try? FileManager.default.createDirectory(
            at: directory(for: meeting.id), withIntermediateDirectories: true
        )
        guard let data = try? encoder.encode(meeting) else {
            Diagnostics.recordError("could not encode meeting \(meeting.id)")
            return
        }
        try? data.write(to: metadataURL(for: meeting.id), options: .atomic)

        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
    }

    func meeting(_ id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard var meeting = meeting(id) else { return }
        change(&meeting)
        save(meeting)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        meetings.removeAll { $0.id == id }
        Diagnostics.log("deleted meeting \(id)")
    }

    // MARK: - Retention

    /// Deletes audio the retention policy says has outlived its purpose.
    ///
    /// Runs at launch and after every transcription. The transcript is never touched — it
    /// is what the user asked for. The audio is other people's voices, and keeping it is
    /// the part that needs a reason.
    func applyRetention() {
        guard let days = AppSettings.shared.retention.days else { return }

        for meeting in meetings where meeting.hasAudio {
            guard meeting.status == .ready else { continue }
            let age = Date().timeIntervalSince(meeting.startedAt)
            guard age >= Double(days) * 86_400 else { continue }
            discardAudio(for: meeting.id)
        }
    }

    func discardAudio(for id: UUID) {
        let manager = FileManager.default
        try? manager.removeItem(at: micURL(for: id))
        try? manager.removeItem(at: systemURL(for: id))
        try? manager.removeItem(at: directory(for: id).appendingPathComponent("chunks"))
        update(id) { $0.hasAudio = false }
        Diagnostics.log("discarded audio for meeting \(id)")
    }

    /// Frees the temporary compressed chunks but keeps the master WAVs.
    func clearChunks(for id: UUID) {
        try? FileManager.default.removeItem(
            at: directory(for: id).appendingPathComponent("chunks")
        )
    }

    var totalAudioBytes: Int {
        meetings.reduce(0) { total, meeting in
            let mic = (try? FileManager.default.attributesOfItem(
                atPath: micURL(for: meeting.id).path)[.size]) as? Int ?? 0
            let system = (try? FileManager.default.attributesOfItem(
                atPath: systemURL(for: meeting.id).path)[.size]) as? Int ?? 0
            return total + mic + system
        }
    }
}
