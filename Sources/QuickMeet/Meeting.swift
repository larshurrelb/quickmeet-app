import Foundation

// MARK: - Speakers

/// A speaker label as it exists on disk.
///
/// `you` is not a diarization result — it is a fact about which microphone the audio came
/// from, and it is the reason this app splits the two streams in the first place. The
/// model never has to guess which voice is the person holding the Mac.
enum SpeakerID: Hashable, Codable {
    case you
    case remote(String)

    var storedValue: String {
        switch self {
        case .you: return "you"
        case let .remote(label): return label
        }
    }

    init(stored: String) {
        self = stored == "you" ? .you : .remote(stored)
    }

    /// The name shown before the user renames anybody.
    var defaultName: String {
        switch self {
        case .you:
            return "You"
        case let .remote(label):
            // "spk_1" is the model's word, not a person's. Turn it into something a human
            // can read at a glance, and keep the number so renaming one does not shuffle
            // the others.
            if let number = label.split(separator: "_").last, let index = Int(number) {
                return "Speaker \(index)"
            }
            return label.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Stable palette index, so a speaker keeps their colour across relaunches.
    var colorIndex: Int {
        switch self {
        case .you:
            return 0
        case let .remote(label):
            if let number = label.split(separator: "_").last, let index = Int(number) {
                return 1 + (index - 1) % 7
            }
            return 1 + abs(label.hashValue) % 7
        }
    }
}

// MARK: - Transcript

struct Turn: Codable, Identifiable, Hashable {
    var id = UUID()
    var speaker: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String

    var speakerID: SpeakerID { SpeakerID(stored: speaker) }
}

// MARK: - Notes

struct ActionItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    /// A speaker label, a name, or empty when the meeting did not say who.
    var owner: String = ""
    var done: Bool = false
}

struct Notes: Codable, Hashable {
    var summary: String = ""
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actionItems: [ActionItem] = []
    var openQuestions: [String] = []
    var suggestedTitle: String = ""

    var isEmpty: Bool {
        summary.isEmpty && keyPoints.isEmpty && decisions.isEmpty
            && actionItems.isEmpty && openQuestions.isEmpty
    }
}

// MARK: - Consent

/// What the user confirmed before recording, kept with the recording.
///
/// This exists because consent is the only part of a meeting recorder that cannot be
/// reconstructed afterwards. A transcript can be re-run; whether the room agreed cannot.
/// Storing it alongside the audio means the answer travels with the thing it is about,
/// including into the exported markdown.
struct ConsentRecord: Codable, Hashable {
    var acknowledged: Bool = false
    var acknowledgedAt: Date?
    /// Free text the user typed — "Anna and Ben, on the call". Never required.
    var note: String = ""
}

// MARK: - Meeting

struct Meeting: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case recording
        case processing
        case ready
        case failed
    }

    var id = UUID()
    var title: String = ""
    var startedAt: Date = Date()
    var duration: TimeInterval = 0
    var status: Status = .recording
    var consent = ConsentRecord()
    var turns: [Turn] = []
    var notes: Notes?
    /// Speaker label → the name the user gave them. Applied at display time so renaming
    /// somebody updates the transcript and the notes together, without a second model
    /// call and without rewriting stored text.
    var speakerNames: [String: String] = [:]
    var micDeviceName: String = ""
    var systemAudioLabel: String = ""
    var systemAudioCaptured: Bool = true
    /// Set when the tap ran but produced nothing usable, so the meeting view can explain
    /// why only one side of the conversation is in the transcript.
    var systemAudioIssue: String?
    var errorMessage: String?
    /// False once the audio has been cleaned up by the retention policy.
    var hasAudio: Bool = true
    /// Progress text while `status == .processing`, e.g. "Transcribing 2 of 3".
    var progress: String = ""

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let suggested = notes?.suggestedTitle, !suggested.isEmpty { return suggested }
        return Self.dateTitleFormatter.string(from: startedAt)
    }

    func name(for speaker: String) -> String {
        if let given = speakerNames[speaker], !given.isEmpty { return given }
        return SpeakerID(stored: speaker).defaultName
    }

    /// Every speaker that actually says something, in the order they first speak.
    var speakers: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for turn in turns where !seen.contains(turn.speaker) {
            seen.insert(turn.speaker)
            ordered.append(turn.speaker)
        }
        return ordered
    }

    static let dateTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM, HH:mm"
        return formatter
    }()

    static func formatted(duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Markdown export

extension Meeting {
    /// The whole meeting as markdown, with names substituted in.
    ///
    /// The consent line is included deliberately and is not optional. If a transcript of
    /// other people's voices is going to be pasted into a ticket or an email, the fact of
    /// whether they agreed to be recorded should travel with it.
    func markdown() -> String {
        var out = "# \(displayTitle)\n\n"
        out += "_\(Meeting.dateTitleFormatter.string(from: startedAt)) · "
        out += "\(Meeting.formatted(duration: duration))_\n\n"

        out += consent.acknowledged
            ? "> Consent confirmed before recording"
            : "> ⚠︎ Consent was not confirmed before recording"
        if !consent.note.isEmpty { out += " — \(consent.note)" }
        out += "\n\n"

        if let notes, !notes.isEmpty {
            if !notes.summary.isEmpty {
                out += "## Summary\n\n\(substituteNames(in: notes.summary))\n\n"
            }
            if !notes.decisions.isEmpty {
                out += "## Decisions\n\n"
                for decision in notes.decisions { out += "- \(substituteNames(in: decision))\n" }
                out += "\n"
            }
            if !notes.actionItems.isEmpty {
                out += "## Action items\n\n"
                for item in notes.actionItems {
                    let owner = item.owner.isEmpty ? "" : " — **\(substituteNames(in: item.owner))**"
                    out += "- [\(item.done ? "x" : " ")] \(substituteNames(in: item.text))\(owner)\n"
                }
                out += "\n"
            }
            if !notes.keyPoints.isEmpty {
                out += "## Key points\n\n"
                for point in notes.keyPoints { out += "- \(substituteNames(in: point))\n" }
                out += "\n"
            }
            if !notes.openQuestions.isEmpty {
                out += "## Open questions\n\n"
                for question in notes.openQuestions { out += "- \(substituteNames(in: question))\n" }
                out += "\n"
            }
        }

        if !turns.isEmpty {
            out += "## Transcript\n\n"
            for turn in turns {
                out += "**\(name(for: turn.speaker))** _(\(Meeting.timestamp(turn.start)))_\n"
                out += "\(turn.text)\n\n"
            }
        }
        return out
    }

    /// Replaces canonical labels with the names the user gave.
    ///
    /// The notes are generated once, against `Speaker 1` and friends, and never
    /// regenerated when somebody is renamed — a rename is a display concern, and paying
    /// for a second summarisation pass to change a word would be absurd.
    func substituteNames(in text: String) -> String {
        var result = text
        for (label, name) in speakerNames where !name.isEmpty {
            result = result.replacingOccurrences(of: SpeakerID(stored: label).defaultName, with: name)
        }
        return result
    }
}
