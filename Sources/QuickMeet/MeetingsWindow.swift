import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The window where a finished meeting actually becomes useful.
///
/// The shape follows what people do with meeting notes: they read the summary once, look
/// for what they agreed to do, and dip into the transcript only to check a specific thing
/// somebody said. So Summary leads, the transcript is one click away rather than scrolled
/// past, and the transcript has a search field because that is the only way anyone
/// navigates an hour of speech.
@MainActor
final class MeetingsWindowController {
    private var window: NSWindow?
    private let store: MeetingStore
    private let onRetry: (UUID) -> Void

    init(store: MeetingStore, onRetry: @escaping (UUID) -> Void) {
        self.store = store
        self.onRetry = onRetry
    }

    func show(selecting id: UUID? = nil) {
        if window == nil { build() }
        if let id { selection.id = id }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Kept outside the SwiftUI tree so `show(selecting:)` can steer it from the menu.
    private let selection = MeetingSelection()

    private func build() {
        let view = MeetingsView(store: store, selection: selection, onRetry: onRetry)
        let hosting = NSHostingView(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickMeet"
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("QuickMeetMain")
        window.minSize = NSSize(width: 820, height: 520)
        window.center()
        self.window = window
    }
}

@MainActor
final class MeetingSelection: ObservableObject {
    @Published var id: UUID?
}

// MARK: - Root

struct MeetingsView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var selection: MeetingSelection
    var onRetry: (UUID) -> Void

    var body: some View {
        NavigationSplitView {
            MeetingList(store: store, selection: selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let id = selection.id, let meeting = store.meetings.first(where: { $0.id == id }) {
                MeetingDetail(meeting: meeting, store: store, onRetry: onRetry)
                    .id(meeting.id)
            } else {
                EmptyDetail(hasMeetings: !store.meetings.isEmpty)
            }
        }
        .onAppear {
            if selection.id == nil { selection.id = store.meetings.first?.id }
        }
    }
}

struct EmptyDetail: View {
    var hasMeetings: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text(hasMeetings ? "Select a meeting" : "No meetings yet")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            if !hasMeetings {
                Text("Start one from the menu bar, or press ⌥⌘R.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar

struct MeetingList: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var selection: MeetingSelection

    var body: some View {
        List(selection: $selection.id) {
            ForEach(grouped, id: \.0) { group, meetings in
                Section(group) {
                    ForEach(meetings) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(meeting.id)
                            .contextMenu {
                                Button("Copy as Markdown") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(meeting.markdown(), forType: .string)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    if selection.id == meeting.id { selection.id = nil }
                                    store.delete(meeting.id)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// "Today", "Yesterday", then the date. Meeting notes are looked up by when the
    /// meeting was, so the grouping is the primary index.
    private var grouped: [(String, [Meeting])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [Meeting]] = [:]

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"

        for meeting in store.meetings {
            let label: String
            if calendar.isDateInToday(meeting.startedAt) {
                label = "Today"
            } else if calendar.isDateInYesterday(meeting.startedAt) {
                label = "Yesterday"
            } else {
                label = formatter.string(from: meeting.startedAt)
            }
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(meeting)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(Self.timeFormatter.string(from: meeting.startedAt))
                    Text("·")
                    Text(Meeting.formatted(duration: meeting.duration))
                    if !meeting.consent.acknowledged {
                        Text("·")
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            switch meeting.status {
            case .processing:
                ProgressView().controlSize(.small).scaleEffect(0.7)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.recordRed)
            case .recording:
                Circle().fill(Theme.recordRed).frame(width: 7, height: 7)
            case .ready:
                EmptyView()
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail

struct MeetingDetail: View {
    let meeting: Meeting
    @ObservedObject var store: MeetingStore
    var onRetry: (UUID) -> Void

    enum Tab: String, CaseIterable { case summary = "Summary", transcript = "Transcript" }

    @State private var tab: Tab = .summary
    @State private var title: String = ""
    @State private var search = ""
    @State private var renaming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            switch meeting.status {
            case .processing, .recording:
                ProcessingState(meeting: meeting)
            case .failed:
                FailedState(meeting: meeting, onRetry: { onRetry(meeting.id) })
            case .ready:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { title = meeting.title.isEmpty ? meeting.displayTitle : meeting.title }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("Meeting title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .semibold))
                    .onSubmit { store.update(meeting.id) { $0.title = title } }

                Spacer(minLength: 8)
                actions
            }

            HStack(spacing: 7) {
                Text(Meeting.dateTitleFormatter.string(from: meeting.startedAt))
                Text("·")
                Text(Meeting.formatted(duration: meeting.duration))
                if !meeting.micDeviceName.isEmpty {
                    Text("·")
                    Text(meeting.micDeviceName)
                }
                if meeting.status == .ready && !meeting.systemAudioCaptured {
                    Text("·")
                    Label("microphone only", systemImage: "speaker.slash")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            HStack(spacing: 8) {
                consentBadge
                if !meeting.speakers.isEmpty {
                    participants
                }
            }

            if let issue = meeting.systemAudioIssue {
                Label(issue, systemImage: "speaker.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    /// The consent state is shown on every meeting, in the header, not tucked into a
    /// detail panel. It is the one piece of metadata that changes what the reader should
    /// do with the transcript.
    private var consentBadge: some View {
        let ok = meeting.consent.acknowledged
        return HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(ok ? "Consent confirmed" : "Consent not confirmed")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(ok ? Color.secondary : Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            (ok ? Color.primary.opacity(0.05) : Color.orange.opacity(0.12)),
            in: Capsule()
        )
        .help(
            meeting.consent.note.isEmpty
                ? (ok ? "Confirmed before recording." : "Recorded without confirming consent.")
                : meeting.consent.note
        )
    }

    private var participants: some View {
        HStack(spacing: 5) {
            ForEach(meeting.speakers, id: \.self) { speaker in
                Button {
                    renaming = speaker
                } label: {
                    SpeakerChip(
                        name: meeting.name(for: speaker),
                        color: Theme.color(for: speaker),
                        compact: true
                    )
                }
                .buttonStyle(.plain)
                .help("Rename")
                .popover(isPresented: Binding(
                    get: { renaming == speaker },
                    set: { if !$0 { renaming = nil } }
                )) {
                    RenameSpeaker(
                        current: meeting.name(for: speaker),
                        onSave: { name in
                            store.update(meeting.id) { $0.speakerNames[speaker] = name }
                            renaming = nil
                        }
                    )
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(meeting.markdown(), forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the whole meeting as Markdown")

            Menu {
                Button("Save as Markdown…") { export() }
                if meeting.status == .ready {
                    Button("Re-transcribe") { onRetry(meeting.id) }
                        .disabled(!meeting.hasAudio)
                }
                if meeting.hasAudio {
                    Button("Show Audio in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.micURL(for: meeting.id)])
                    }
                    Button("Delete Audio, Keep Notes") { store.discardAudio(for: meeting.id) }
                }
                Divider()
                Button("Delete Meeting", role: .destructive) { store.delete(meeting.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .font(.system(size: 12))
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = meeting.displayTitle
            .replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? meeting.markdown().write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.vertical, 12)

            Divider()

            switch tab {
            case .summary:
                SummaryPane(meeting: meeting, store: store)
            case .transcript:
                TranscriptPane(meeting: meeting, search: $search)
            }
        }
    }
}

struct RenameSpeaker: View {
    let current: String
    var onSave: (String) -> Void

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speaker name")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit { onSave(name.trimmingCharacters(in: .whitespaces)) }
            Text("Applies to the transcript and the notes.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .onAppear { name = current }
    }
}

// MARK: - States

struct ProcessingState: View {
    let meeting: Meeting

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(meeting.progress.isEmpty ? "Working…" : meeting.progress)
                .font(.system(size: 13, weight: .medium))
            Text("You can close this window — it keeps going.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailedState: View {
    let meeting: Meeting
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.orange)
            Text(meeting.errorMessage ?? "Something went wrong.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if meeting.hasAudio {
                Button("Retry", action: onRetry)
                    .controlSize(.large)
                Text("The audio is still on this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text("The audio for this meeting has already been deleted.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
