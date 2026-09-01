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
///
/// The two columns are a plain `HStack`, and that is a deliberate retreat from
/// `NavigationSplitView`. Hosted in a hand-built `NSWindow` — no `Scene`, no toolbar — the
/// split view brought its own titlebar handling with it and none of it could be relied on:
/// its columns reported no safe area, its sidebar list carried scroll insets that vanished
/// the moment anything was stacked around it (so rows scrolled up behind the traffic
/// lights and stayed there), swapping one split view for another left the detail column
/// blank, and its collapse button hid the sidebar with no way back — the button lives in
/// the sidebar it just hid. None of those are bugs in a two-column layout; they are the
/// cost of a container that expects a window it did not get. An `HStack` in a window
/// whose content starts *below* the titlebar has no such surface: nothing can be drawn
/// under the traffic lights because nothing is laid out there.
@MainActor
final class MeetingsWindowController {
    private var window: NSWindow?
    private let store: MeetingStore
    private let onRetry: (UUID) -> Void
    private let onToggleRecording: () -> Void

    init(
        store: MeetingStore,
        onRetry: @escaping (UUID) -> Void,
        onToggleRecording: @escaping () -> Void
    ) {
        self.store = store
        self.onRetry = onRetry
        self.onToggleRecording = onToggleRecording
    }

    func show(selecting id: UUID? = nil) {
        if window == nil { build() }
        if let id {
            navigation.id = id
            navigation.showingSettings = false
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        fitToScreen()
    }

    /// Settings is a page of this window rather than a window of its own.
    ///
    /// Two windows for one small app meant two things called "QuickMeet" in the window
    /// list and no way to get from one to the other. The sidebar's Settings button and
    /// this method are the same door.
    func showSettings() {
        show()
        navigation.showingSettings = true
    }

    /// Kept outside the SwiftUI tree so the status menu can steer it.
    private let navigation = MeetingsNavigation()

    private func build() {
        let view = MeetingsView(
            store: store,
            navigation: navigation,
            onRetry: onRetry,
            onToggleRecording: onToggleRecording
        )
        let hosting = NSHostingView(rootView: view)

        // Safe here, and necessary. `sizingOptions` defaults to pushing the SwiftUI
        // content's minimum and maximum size onto the window, which is what made resizing
        // fight back. This window's size is set below and its `fittingSize` is never read,
        // which is exactly the case the flag is for — see the opposite mistake in
        // `ConsentWindowController`, where zeroing it built a 0×0 window.
        hosting.sizingOptions = []

        // `fullSizeContentView` with a titlebar that draws nothing, so the sidebar runs the
        // full height of the window and there is no line ruled across it under the traffic
        // lights.
        //
        // This is the flag that put UI behind the traffic lights in every earlier version,
        // and the rule that makes it safe is narrow: **only decoration ignores the safe
        // area.** SwiftUI hands a plain root view a top safe area the height of the titlebar
        // (measured: 32), so every container here — both columns, both scroll views — is
        // laid out below it and cannot scroll anything up into it. The sidebar's background
        // and its trailing hairline are the only things that opt out, and they are colour,
        // not content.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickMeet"
        // The sidebar's heading says the app's name, with its icon; the titlebar would only
        // be repeating it — and drawing it would put a backdrop over the sidebar.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        // Small enough to be usable on a laptop screen next to a call window.
        window.minSize = NSSize(width: 720, height: 440)
        window.setFrameAutosaveName("QuickMeetMain")
        if !window.setFrameUsingName("QuickMeetMain") { window.center() }
        self.window = window
    }

    /// Pulls the window back onto the screen it is on.
    ///
    /// Restored frames outlive the display they were saved on: unplug a big monitor and
    /// the remembered 700-point-tall window is taller than a laptop's working area, so it
    /// hangs off the bottom with its lower half — and its resize corner — unreachable.
    /// Menu bar and Dock are already excluded from `visibleFrame`, so fitting to it is the
    /// whole fix.
    private func fitToScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame

        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)

        guard frame != window.frame else { return }
        window.setFrame(frame, display: true)
        Diagnostics.log("main window refitted to screen: \(Int(frame.width))x\(Int(frame.height))")
    }
}

/// What the window is showing: which meeting, and whether Settings is up.
@MainActor
final class MeetingsNavigation: ObservableObject {
    @Published var id: UUID?
    @Published var showingSettings = false
    @Published var settingsSection: SettingsSection = .setup
}

// MARK: - Root

struct MeetingsView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var navigation: MeetingsNavigation
    var onRetry: (UUID) -> Void
    var onToggleRecording: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if navigation.id == nil { navigation.id = store.meetings.first?.id }
        }
    }

    /// Settings borrows the meetings sidebar rather than replacing the window: same width,
    /// same rows, and the button in the bottom corner swaps between the two either way.
    @ViewBuilder
    private var sidebar: some View {
        if navigation.showingSettings {
            // No record button in settings: nothing on that page is about the meeting you
            // are in, and the menu bar and ⌥⌘R are still there if you need to start one.
            Sidebar(recording: recording, onToggleRecording: nil) {
                SettingsCategories(navigation: navigation)
            } footer: {
                SidebarButton(icon: "chevron.left", title: "Meetings") {
                    navigation.showingSettings = false
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        } else {
            Sidebar(recording: recording, onToggleRecording: onToggleRecording) {
                MeetingList(store: store, navigation: navigation)
            } footer: {
                SidebarButton(icon: "gearshape", title: "Settings") {
                    navigation.showingSettings = true
                }
            }
        }
    }

    /// Read from the meetings rather than from the recorder: a meeting in progress is one
    /// with `status == .recording`, which the store already publishes. The window does not
    /// need a second source of truth for it, and the same flag draws the red dot on the row.
    private var recording: Bool {
        store.meetings.contains { $0.status == .recording }
    }

    @ViewBuilder
    private var detail: some View {
        if navigation.showingSettings {
            SettingsView(store: store, section: navigation.settingsSection)
                .id(navigation.settingsSection)
        } else if let id = navigation.id,
                  let meeting = store.meetings.first(where: { $0.id == id }) {
            MeetingDetail(
                meeting: meeting,
                // Built here, where it is built exactly once per render. A computed
                // property on the detail view would rebuild on every access instead, and
                // every access walks the whole transcript.
                speakers: meeting.speakerDirectory,
                store: store,
                onRetry: onRetry
            )
            .id(meeting.id)
        } else {
            EmptyDetail(hasMeetings: !store.meetings.isEmpty)
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

/// The sidebar's chrome: heading, a scrolling middle, one button pinned at the bottom.
///
/// Fixed width and not collapsible, on purpose. The collapsible version put its own toggle
/// *inside* the column it collapsed, so hiding the sidebar hid the only way to bring it
/// back — the meetings list and the settings both became unreachable in one click.
struct Sidebar<Content: View, Footer: View>: View {
    var recording: Bool
    /// Nil where the page has no business starting a recording, which hides the button.
    var onToggleRecording: (() -> Void)?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    static var width: CGFloat { 244 }

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeading(recording: recording, onToggleRecording: onToggleRecording)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    content
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            footer
        }
        .frame(width: Self.width)
        // The column's colour and the hairline that separates it from the detail pane, both
        // running the whole height of the window — up past the traffic lights, which is the
        // only thing here allowed to ignore the safe area. The hairline replaces the
        // `Divider()` that used to sit between the columns, because a divider in the stack
        // would start below the titlebar and leave a notch at the top.
        .background(alignment: .trailing) {
            ZStack(alignment: .trailing) {
                Color.primary.opacity(0.035)
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1)
            }
            .ignoresSafeArea(edges: .top)
        }
    }
}

/// The app's mark and name.
struct SidebarHeading: View {
    var recording: Bool
    var onToggleRecording: (() -> Void)?

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            // The logo without its tile, not `NSApp.applicationIconImage` — the Dock icon
            // carries a rounded square that looks wrong inline next to text.
            if let logo = Branding.logo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 21, height: 21)
                    .accessibilityHidden(true)
            }
            Text("QuickMeet")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 4)
            if let onToggleRecording { recordButton(onToggleRecording) }
        }
        // Fixed, so the rows below it sit at the same height whether or not the button is
        // there — switching to settings should not shunt the list up by a few points.
        .frame(height: 24)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// Starts and stops a meeting, next to the app's name.
    ///
    /// It is the same action as the menu bar's and as ⌥⌘R, and it goes through the same
    /// gates — key, consent, microphone — because it calls the same method. Nothing about
    /// recording is decided here.
    private func recordButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: recording ? "stop.fill" : "record.circle.fill")
                    .font(.system(size: recording ? 9 : 11))
                Text(recording ? "Stop" : "Record")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.recordRed)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Theme.recordRed.opacity(hovered ? 0.22 : 0.14),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(recording ? "Stop the meeting (⌥⌘R)" : "Record a meeting (⌥⌘R)")
    }
}

/// One row of the sidebar, in either mode: a meeting, a settings category, or the button at
/// the bottom. Selection and hover are drawn here so all three look and behave alike.
struct SidebarButton<Label: View>: View {
    var selected = false
    var action: () -> Void
    @ViewBuilder var label: Label

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                // The row's own text sets its sizes; this is only the default for the
                // plain icon-and-text form below.
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(fill, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var fill: Color {
        if selected { return Color.accentColor.opacity(0.18) }
        return hovered ? Color.primary.opacity(0.07) : .clear
    }
}

extension SidebarButton where Label == SwiftUI.Label<Text, Image> {
    /// The plain icon-and-text form, used for the settings categories and both footers.
    init(icon: String, title: String, selected: Bool = false, action: @escaping () -> Void) {
        self.init(selected: selected, action: action) {
            SwiftUI.Label(title, systemImage: icon)
        }
    }
}

struct MeetingList: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var navigation: MeetingsNavigation

    var body: some View {
        ForEach(grouped, id: \.0) { group, meetings in
            Text(group)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 2)

            ForEach(meetings) { meeting in
                SidebarButton(selected: navigation.id == meeting.id) {
                    navigation.id = meeting.id
                } label: {
                    MeetingRow(meeting: meeting)
                }
                .contextMenu {
                    Button("Copy as Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(meeting.markdown(), forType: .string)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        if navigation.id == meeting.id { navigation.id = nil }
                        store.delete(meeting.id)
                    }
                }
            }
        }
    }

    /// "Today", "Yesterday", then the date. Meeting notes are looked up by when the
    /// meeting was, so the grouping is the primary index.
    private var grouped: [(String, [Meeting])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [Meeting]] = [:]

        for meeting in store.meetings {
            let label: String
            if calendar.isDateInToday(meeting.startedAt) {
                label = "Today"
            } else if calendar.isDateInYesterday(meeting.startedAt) {
                label = "Yesterday"
            } else {
                label = Self.dayFormatter.string(from: meeting.startedAt)
            }
            if buckets[label] == nil { order.append(label) }
            buckets[label, default: []].append(meeting)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()
}

struct SettingsCategories: View {
    @ObservedObject var navigation: MeetingsNavigation

    var body: some View {
        ForEach(SettingsSection.allCases) { item in
            SidebarButton(
                icon: item.icon,
                title: item.title,
                selected: navigation.settingsSection == item
            ) {
                navigation.settingsSection = item
            }
        }
        .padding(.top, 2)
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
    }
}

// MARK: - Detail

struct MeetingDetail: View {
    let meeting: Meeting
    let speakers: SpeakerDirectory
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
                if !speakers.order.isEmpty {
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
            ForEach(speakers.order, id: \.self) { speaker in
                Button {
                    renaming = speaker
                } label: {
                    SpeakerChip(
                        name: speakers.name(of: speaker),
                        color: Theme.color(index: speakers.index(of: speaker)),
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
                        current: speakers.name(of: speaker),
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
                SummaryPane(meeting: meeting, speakers: speakers, store: store)
            case .transcript:
                TranscriptPane(meeting: meeting, speakers: speakers, search: $search)
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
