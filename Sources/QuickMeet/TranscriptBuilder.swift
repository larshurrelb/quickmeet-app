import Foundation

/// Turns per-chunk model output into one transcript on one clock.
///
/// Three problems live here, and none of them are the model's fault:
///
///  1. Speaker labels are only meaningful inside a single request, so a two-hour meeting
///     transcribed in six chunks calls the same person `spk_1`, `spk_2`, `spk_1`, … The
///     chunks overlap by design, and the same voice occupies the same seconds in both, so
///     the labels can be matched up by time rather than by guessing or by spending another
///     model call on it.
///  2. The overlap that makes (1) possible also duplicates twenty seconds of speech, which
///     has to come back out.
///  3. If the user is on speakers rather than headphones, their microphone also hears the
///     far end — so the same sentence arrives on both streams and would appear twice, once
///     misattributed to the user.
enum TranscriptBuilder {
    /// A new turn starts after this much silence from the same speaker. Long enough not to
    /// split a sentence at a breath, short enough that a monologue is still readable.
    static let turnGap: TimeInterval = 1.2

    /// How close two words must be to count as the same moment when matching speakers
    /// across a chunk boundary. Chunk clocks are exact — the slices come from the same
    /// byte stream — so this only has to absorb the model's own timing wobble.
    static let matchWindow: TimeInterval = 1.5

    struct ChunkResult {
        let offset: TimeInterval
        let duration: TimeInterval
        let words: [TranscribedWord]
    }

    // MARK: - One stream

    /// Stitches one stream's chunks into a single word list on the meeting clock.
    static func assemble(_ chunks: [ChunkResult]) -> [TranscribedWord] {
        var assembled: [TranscribedWord] = []
        var previousEnd: TimeInterval = 0

        for (index, chunk) in chunks.enumerated() {
            var words = chunk.words.map { word -> TranscribedWord in
                var moved = word
                moved.start += chunk.offset
                moved.end += chunk.offset
                return moved
            }

            if index > 0 {
                let overlapStart = chunk.offset
                let overlapEnd = min(previousEnd, chunk.offset + chunk.duration)

                if overlapEnd > overlapStart {
                    let mapping = speakerMapping(
                        newWords: words,
                        against: assembled,
                        overlap: overlapStart...overlapEnd
                    )
                    if !mapping.isEmpty {
                        words = words.map { word in
                            var mapped = word
                            if let speaker = word.speaker, let canonical = mapping[speaker] {
                                mapped.speaker = canonical
                            }
                            return mapped
                        }
                    }

                    // Cut both sides at the same instant, in the middle of the overlap.
                    //
                    // Trimming only the incoming chunk is not enough: the previous chunk
                    // also transcribed the whole shared stretch, so everything after the
                    // seam exists twice. Both halves of this cut are needed — the seam is
                    // a single point that the earlier chunk owns up to and the later chunk
                    // owns from.
                    //
                    // The midpoint rather than either edge, because a word is least
                    // reliable at the very end of a chunk (no audio after it) and at the
                    // very start of one (no audio before it). The middle of the overlap is
                    // the only place both chunks heard it with context on both sides.
                    let seam = overlapStart + (overlapEnd - overlapStart) / 2
                    assembled.removeAll { $0.start >= seam }
                    words = words.filter { $0.start >= seam }
                }
            }

            assembled.append(contentsOf: words)
            previousEnd = chunk.offset + chunk.duration
        }

        return assembled.sorted { $0.start < $1.start }
    }

    /// Works out which of the new chunk's labels are which of the established ones, by
    /// asking who was speaking at the same instant in both.
    static func speakerMapping(
        newWords: [TranscribedWord],
        against established: [TranscribedWord],
        overlap: ClosedRange<TimeInterval>
    ) -> [String: String] {
        let reference = established.filter { overlap.contains($0.start) && $0.speaker != nil }
        let candidates = newWords.filter { overlap.contains($0.start) && $0.speaker != nil }
        guard !reference.isEmpty, !candidates.isEmpty else { return [:] }

        var votes: [String: [String: Int]] = [:]
        for word in candidates {
            guard let label = word.speaker else { continue }
            let nearest = reference.min {
                abs($0.start - word.start) < abs($1.start - word.start)
            }
            guard let nearest, let canonical = nearest.speaker,
                  abs(nearest.start - word.start) <= matchWindow
            else { continue }
            votes[label, default: [:]][canonical, default: 0] += 1
        }

        // Greedy one-to-one assignment, strongest agreement first. Two different new
        // labels must never collapse onto one established speaker — that would merge two
        // people into one for the rest of the meeting, which is worse than leaving a
        // stranger unmatched.
        var pairs: [(new: String, canonical: String, count: Int)] = []
        for (label, tally) in votes {
            for (canonical, count) in tally {
                pairs.append((label, canonical, count))
            }
        }
        pairs.sort { $0.count > $1.count }

        var mapping: [String: String] = [:]
        var claimed = Set<String>()
        for pair in pairs {
            guard mapping[pair.new] == nil, !claimed.contains(pair.canonical) else { continue }
            mapping[pair.new] = pair.canonical
            claimed.insert(pair.canonical)
        }

        // Anyone who only joined after the boundary gets a label that cannot collide with
        // an existing one.
        var next = (established.compactMap { $0.speaker.flatMap(index(ofLabel:)) }.max() ?? 0) + 1
        for label in Set(candidates.compactMap(\.speaker)) where mapping[label] == nil {
            mapping[label] = "spk_\(next)"
            next += 1
        }

        Diagnostics.log("speaker stitch across chunk boundary: \(mapping.sorted { $0.key < $1.key })")
        return mapping
    }

    private static func index(ofLabel label: String) -> Int? {
        guard let last = label.split(separator: "_").last else { return nil }
        return Int(last)
    }

    // MARK: - Turns

    /// Groups words into readable turns.
    ///
    /// - Parameter fallbackSpeaker: used when the words carry no label at all, which is
    ///   every word on the microphone stream — that one is `you` by construction.
    static func turns(from words: [TranscribedWord], fallbackSpeaker: String) -> [Turn] {
        var turns: [Turn] = []
        var current: Turn?

        for word in words {
            let speaker = word.speaker ?? fallbackSpeaker

            if var existing = current,
               existing.speaker == speaker,
               word.start - existing.end <= turnGap {
                existing.text = join(existing.text, word.text)
                existing.end = max(existing.end, word.end)
                current = existing
            } else {
                if let existing = current { turns.append(existing) }
                current = Turn(
                    speaker: speaker,
                    start: word.start,
                    end: max(word.end, word.start),
                    text: word.text
                )
            }
        }
        if let existing = current { turns.append(existing) }

        return turns.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Word-by-word joining that does not put a space before punctuation. The model
    /// returns punctuation attached to words most of the time and standalone sometimes.
    static func join(_ text: String, _ word: String) -> String {
        guard let first = word.first else { return text }
        if ",.!?;:)]}".contains(first) || word.hasPrefix("'") || word.hasPrefix("’") {
            return text + word
        }
        if let last = text.last, "([{".contains(last) {
            return text + word
        }
        return text + " " + word
    }

    // MARK: - Merging the two streams

    /// Interleaves your turns with theirs, and removes what the microphone overheard.
    static func merge(mic: [Turn], system: [Turn]) -> [Turn] {
        let cleaned = removeEcho(mic: mic, system: system)
        return (cleaned + system).sorted {
            $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start
        }
    }

    /// Drops microphone turns that are really the far end coming back through the speakers.
    ///
    /// Without headphones the microphone hears everything the Mac plays, so the other
    /// people's sentences arrive on both streams — and the microphone copy is labelled
    /// `you`. Attributing someone else's words to the user is the single most damaging
    /// thing this app could get wrong, so an overlapping turn that shares most of its
    /// words with a system turn is treated as an echo and dropped. The system stream is
    /// kept because it is the one with the correct speaker on it.
    static func removeEcho(mic: [Turn], system: [Turn]) -> [Turn] {
        guard !system.isEmpty else { return mic }

        return mic.filter { turn in
            let overlapping = system.filter { $0.start < turn.end && $0.end > turn.start }
            guard !overlapping.isEmpty else { return true }

            let mine = wordSet(turn.text)
            guard mine.count >= 3 else {
                // Too short to judge. "Yeah", "mhm" and "exactly" are things the user
                // genuinely says over someone else, and throwing them away would quietly
                // delete half of a conversation's texture.
                return true
            }

            for other in overlapping {
                let theirs = wordSet(other.text)
                guard !theirs.isEmpty else { continue }
                let shared = mine.intersection(theirs).count
                if Double(shared) / Double(mine.count) >= 0.6 {
                    Diagnostics.log("dropped echoed mic turn at \(Int(turn.start))s (\(shared)/\(mine.count) words)")
                    return false
                }
            }
            return true
        }
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )
    }
}
