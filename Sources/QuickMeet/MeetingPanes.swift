import AppKit
import SwiftUI

// MARK: - Summary

/// What the meeting was, in the order someone actually wants it.
///
/// Action items come before key points on purpose. The question people open meeting notes
/// to answer is "what did I agree to do", and burying that under a wall of bullet points
/// is how notes go unread.
struct SummaryPane: View {
    let meeting: Meeting
    @ObservedObject var store: MeetingStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let notes = meeting.notes, !notes.isEmpty {
                    if !notes.summary.isEmpty {
                        Card {
                            Text(meeting.substituteNames(in: notes.summary))
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                        }
                    }

                    if !notes.actionItems.isEmpty {
                        Card(title: "Action items", systemImage: "checkmark.circle") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(notes.actionItems) { item in
                                    ActionItemRow(
                                        item: item,
                                        meeting: meeting,
                                        onToggle: { toggle(item) }
                                    )
                                }
                            }
                        }
                    }

                    if !notes.decisions.isEmpty {
                        Card(title: "Decisions", systemImage: "flag") {
                            bullets(notes.decisions)
                        }
                    }

                    if !notes.keyPoints.isEmpty {
                        Card(title: "Key points", systemImage: "list.bullet") {
                            bullets(notes.keyPoints)
                        }
                    }

                    if !notes.openQuestions.isEmpty {
                        Card(title: "Open questions", systemImage: "questionmark.circle") {
                            bullets(notes.openQuestions)
                        }
                    }
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No notes for this meeting")
                                .font(.system(size: 13, weight: .medium))
                            Text("The transcript is there — the summary pass didn't produce anything. Check Copy Diagnostics in the menu bar for why.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !meeting.consent.note.isEmpty {
                    Card(title: "Consent", systemImage: "checkmark.seal") {
                        Text(meeting.consent.note)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(24)
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                    Text(meeting.substituteNames(in: item))
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func toggle(_ item: ActionItem) {
        store.update(meeting.id) { meeting in
            guard var notes = meeting.notes,
                  let index = notes.actionItems.firstIndex(where: { $0.id == item.id })
            else { return }
            notes.actionItems[index].done.toggle()
            meeting.notes = notes
        }
    }
}

struct ActionItemRow: View {
    let item: ActionItem
    let meeting: Meeting
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Text(meeting.substituteNames(in: item.text))
                .font(.system(size: 13))
                .strikethrough(item.done, color: .secondary)
                .foregroundStyle(item.done ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !item.owner.isEmpty {
                SpeakerChip(
                    name: meeting.substituteNames(in: item.owner),
                    color: ownerColor,
                    compact: true
                )
            }
        }
    }

    /// Colour the owner chip like the speaker it names, when it names one — so an action
    /// item lines up visually with the person in the transcript who took it on.
    private var ownerColor: Color {
        for speaker in meeting.speakers where meeting.name(for: speaker) == item.owner {
            return Theme.color(for: speaker)
        }
        return .secondary
    }
}

// MARK: - Transcript

struct TranscriptPane: View {
    let meeting: Meeting
    @Binding var search: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search the transcript", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !search.isEmpty {
                    Text("\(filtered.count) of \(meeting.turns.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 9)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(filtered) { turn in
                        TurnRow(turn: turn, meeting: meeting, highlight: search)
                    }
                }
                .padding(24)
            }
        }
    }

    private var filtered: [Turn] {
        guard !search.isEmpty else { return meeting.turns }
        return meeting.turns.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }
}

struct TurnRow: View {
    let turn: Turn
    let meeting: Meeting
    let highlight: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                SpeakerChip(
                    name: meeting.name(for: turn.speaker),
                    color: Theme.color(for: turn.speaker)
                )
                Text(Meeting.timestamp(turn.start))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            Text(attributed)
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 2)
        .overlay(alignment: .leading) {
            // A hairline in the speaker's colour down the left edge — enough to track who
            // is talking while skimming, without a chip on every line.
            Rectangle()
                .fill(Theme.color(for: turn.speaker).opacity(0.35))
                .frame(width: 2)
                .padding(.vertical, 1)
                .offset(x: -10)
        }
    }

    /// Marks search hits inside the turn, so a search result is findable in the sentence
    /// rather than just in the list.
    private var attributed: AttributedString {
        var text = AttributedString(turn.text)
        guard !highlight.isEmpty else { return text }

        var searchRange = text.startIndex..<text.endIndex
        while let found = text[searchRange].range(of: highlight, options: .caseInsensitive) {
            text[found].backgroundColor = Color.yellow.opacity(0.35)
            guard found.upperBound < text.endIndex else { break }
            searchRange = found.upperBound..<text.endIndex
        }
        return text
    }
}
