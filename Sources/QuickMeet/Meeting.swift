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

    /// The name this speaker was shown under by earlier builds.
    ///
    /// Nothing displays this any more — `SpeakerDirectory` names people from the order they
    /// speak rather than from the label's text. It survives only so that notes written by an
    /// older build, which have "Spk:0" baked into their sentences, can still be brought in
    /// line with what the transcript now calls that person.
    var legacyName: String {
        switch self {
        case .you:
            return "You"
        case let .remote(label):
            // Deliberately the old parse, underscores only, warts and all: the point is to
            // reproduce the string an older build actually wrote into its notes. Reading
            // "spk:0" correctly here would find nothing to replace.
            if let number = label.split(separator: "_").last, let index = Int(number) {
                return "Speaker \(index)"
            }
            return label.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The trailing number in a model-supplied label, whatever separates it.
    ///
    /// The label comes back from Gemini verbatim and its shape is not contractual:
    /// `spk_1`, `spk:0` and `speaker 2` have all been seen from the same endpoint. A parse
    /// that only understood `_` returned nil for the others, which is how "Spk:0" ended up
    /// on screen and how two late-joining speakers could be handed the same stitched label.
    ///
    /// Used by `TranscriptBuilder` to number a speaker who joins after a chunk boundary.
    static func number(inLabel label: String) -> Int? {
        let digits = label.reversed().prefix { $0.isNumber }.reversed()
        return digits.isEmpty ? nil : Int(String(digits))
    }
}

// MARK: - Transcript

struct Turn: Codable, Identifiable, Hashable {
    var id = UUID()
    var speaker: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
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

    /// Everything the interface needs to know about who spoke, worked out in one pass.
    ///
    /// The obvious shape — `name(for:)`, `speakerIndex(for:)` and `speakers` as methods on
    /// `Meeting` — makes each of them walk the whole turn list, and every caller wants all
    /// three *per line*. That is quadratic in the number of turns: `markdown()` on a
    /// two-hour meeting called `name(for:)` once per turn, and each of those calls walked
    /// every turn again. The transcript pane and the notes prompt had the same shape.
    ///
    /// So build one of these at the top of whatever is about to render or export, and hand
    /// it down. Nothing here is cached on the meeting itself: the turns change when a
    /// transcript is re-run and the names change when the user renames somebody, and a
    /// stale directory would put the wrong name on the wrong voice.
    var speakerDirectory: SpeakerDirectory { SpeakerDirectory(self) }

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


// MARK: - Speaker directory

/// Who spoke, what they are called, and what they used to be called.
///
/// Built in a single pass over the turns, because everything in here is derived from the
/// order people first speak and the names the user has since given them — and the callers
/// want all of it at once, per line.
struct SpeakerDirectory {
    /// Speakers in the order they first speak, the user included wherever they land.
    let order: [String]

    private let indices: [String: Int]
    private let names: [String: String]
    /// Every earlier spelling of a name, mapped to what that person is called now. Longest
    /// first, so "Speaker 10" is never chewed up by the rule for "Speaker 1".
    private let replacements: [(old: String, new: String)]
    private let remoteCount: Int

    init(_ meeting: Meeting) {
        let you = SpeakerID.you.storedValue

        var order: [String] = []
        var indices: [String: Int] = [:]
        var remotes = 0
        for turn in meeting.turns where indices[turn.speaker] == nil {
            order.append(turn.speaker)
            if turn.speaker == you {
                indices[you] = 0
            } else {
                remotes += 1
                indices[turn.speaker] = remotes
            }
        }

        var names: [String: String] = [:]
        var replacements: [(old: String, new: String)] = []
        for speaker in order {
            let fallback = Self.defaultName(index: indices[speaker] ?? 0)
            let given = meeting.speakerNames[speaker] ?? ""
            let shown = given.isEmpty ? fallback : given
            names[speaker] = shown
            for prior in Self.priorNames(of: speaker, fallback: fallback) where prior != shown {
                replacements.append((prior, shown))
            }
        }

        self.order = order
        self.indices = indices
        self.names = names
        self.replacements = replacements.sorted { $0.old.count > $1.old.count }
        self.remoteCount = remotes
    }

    /// 0 for the user, then 1… for everyone else in the order they first speak. Name and
    /// colour both come from this, so "Speaker 2" is always the colour of the second person
    /// to talk.
    ///
    /// Deliberately derived from that order and not from the stored label. The label is the
    /// model's word — `spk_1`, `spk:0`, `speaker 2` are all shapes the same endpoint has
    /// returned — and the numbering starts at 0 as often as at 1. Printing it raw put
    /// "Spk:0" in front of the user. A meeting has a first speaker; it has no zeroth one.
    func index(of speaker: String) -> Int {
        indices[speaker] ?? (speaker == SpeakerID.you.storedValue ? 0 : remoteCount + 1)
    }

    func name(of speaker: String) -> String {
        names[speaker] ?? Self.defaultName(index: index(of: speaker))
    }

    /// Brings the names inside stored notes text up to date.
    ///
    /// The notes are generated once, against whatever the speakers were called at the time,
    /// and never regenerated — a rename is a display concern, and paying for a second
    /// summarisation pass to change a word would be absurd. So every earlier spelling has
    /// to be swapped out here: the name the user has since given somebody, and also the raw
    /// "Spk:0" that older builds wrote into the notes before speakers were numbered from
    /// the order they speak.
    func substituting(in text: String) -> String {
        replacements.reduce(text) { $0.replacingOccurrences(of: $1.old, with: $1.new) }
    }

    private static func defaultName(index: Int) -> String {
        index == 0 ? "You" : "Speaker \(index)"
    }

    /// Spellings of a speaker that could be sitting in notes written earlier.
    ///
    /// The raw label is only offered when it is long enough and numbered enough to be
    /// unmistakable. A one- or two-character label — the model has been known to return
    /// bare letters — would match halfway through ordinary words and shred the notes.
    private static func priorNames(of speaker: String, fallback: String) -> [String] {
        guard speaker != SpeakerID.you.storedValue else { return ["You"] }
        return [fallback] + [SpeakerID(stored: speaker).legacyName, speaker]
            .filter { $0.count >= 3 && $0.contains(where: \.isNumber) }
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
        // Once, not per line: this used to call `name(for:)` inside the transcript loop,
        // and each of those calls walked every turn in the meeting.
        let speakers = speakerDirectory

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
                out += "## Summary\n\n\(speakers.substituting(in: notes.summary))\n\n"
            }
            out += section("Decisions", notes.decisions, speakers)
            if !notes.actionItems.isEmpty {
                out += "## Action items\n\n"
                for item in notes.actionItems {
                    let owner = item.owner.isEmpty
                        ? ""
                        : " — **\(speakers.substituting(in: item.owner))**"
                    out += "- [\(item.done ? "x" : " ")] "
                        + "\(speakers.substituting(in: item.text))\(owner)\n"
                }
                out += "\n"
            }
            out += section("Key points", notes.keyPoints, speakers)
            out += section("Open questions", notes.openQuestions, speakers)
        }

        if !turns.isEmpty {
            out += "## Transcript\n\n"
            for turn in turns {
                out += "**\(speakers.name(of: turn.speaker))** _(\(Meeting.timestamp(turn.start)))_\n"
                out += "\(turn.text)\n\n"
            }
        }
        return out
    }

    private func section(
        _ heading: String, _ items: [String], _ speakers: SpeakerDirectory
    ) -> String {
        guard !items.isEmpty else { return "" }
        return "## \(heading)\n\n"
            + items.map { "- \(speakers.substituting(in: $0))\n" }.joined()
            + "\n"
    }
}
