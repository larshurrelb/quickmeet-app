import AppKit
import AVFoundation
import SwiftUI

/// Settings, in the meetings window and wearing its shape.
///
/// It used to be a window of its own, which meant two things called "QuickMeet" in the
/// window list and no way to get from one to the other. Now it is the same window with the
/// same sidebar-and-detail split — the sidebar lists the categories where it otherwise
/// lists meetings, and the button in the bottom-left corner swaps between the two, in the
/// same place either way.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    /// Everything that has to be true before a recording can work at all, on one page and
    /// first in the list. Splitting the key from the microphone from the system-audio
    /// permission meant a new user had to visit three pages to find out what was still
    /// missing.
    case setup
    case consent
    case notes
    case recordings
    case general

    var id: Self { self }

    var title: String {
        switch self {
        case .setup: return "Setup"
        case .consent: return "Consent"
        case .notes: return "Notes"
        case .recordings: return "Recordings"
        case .general: return "General"
        }
    }

    var icon: String {
        switch self {
        case .setup: return "checklist"
        case .consent: return "person.2.wave.2"
        case .notes: return "text.append"
        case .recordings: return "internaldrive"
        case .general: return "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: MeetingStore
    var section: SettingsSection

    private let settings = AppSettings.shared

    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var microphoneUID = ""
    @State private var recordSystem = true
    @State private var systemSourceID = ""
    @State private var retention = AudioRetention.keepSevenDays
    @State private var notesLanguage = ""
    @State private var askEveryTime = true
    @State private var playSound = true
    @State private var hotkeyEnabled = true
    @State private var probeResult: Bool?
    @State private var micGranted = MicRecorder.hasMicrophoneAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The page title is outside the scroll view, and not only because it should
            // stay put while the page scrolls. A `ScrollView` that touches the top of the
            // window extends *into* the titlebar and insets its content instead (measured:
            // `contentInsets.top` 32), so scrolled text slides up to the window's very top
            // edge with a transparent titlebar over it. Anything non-scrolling above it —
            // this heading — stops that.
            Text(section.title)
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case .setup:
                        setupSection
                    case .consent:
                        consentSection
                    case .notes:
                        notesSection
                    case .recordings:
                        storageSection
                    case .general:
                        generalSection
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                // A readable column instead of a hard size. The old fixed 520×640 frame was
                // what the settings *window* was, and dropping it into a resizable window
                // unchanged would have pinned it to that size in the middle of the pane.
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: load)
    }

    private func load() {
        apiKey = settings.apiKey
        microphoneUID = settings.microphoneUID
        recordSystem = settings.recordSystemAudio
        systemSourceID = settings.systemAudioSource.storedValue
        retention = settings.retention
        notesLanguage = settings.notesLanguage
        askEveryTime = settings.askConsentEveryTime
        playSound = settings.playSound
        hotkeyEnabled = settings.hotkeyEnabled
        micGranted = MicRecorder.hasMicrophoneAccess
    }

    // MARK: - Setup

    /// One page with everything that has to be done before a recording works: the key, the
    /// microphone, the system-audio permission. The checklist at the top answers "why isn't
    /// this working" without reading any of the prose underneath it.
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            readiness
            apiSection
            Divider()
            audioSection
        }
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 6) {
            readinessRow(
                done: settings.hasAPIKey,
                "Gemini API key",
                settings.hasAPIKey ? "Saved on this Mac" : "Needed — paste one below"
            )
            readinessRow(
                done: micGranted,
                "Microphone",
                micGranted ? "Allowed" : "macOS will ask on your first recording"
            )
            if recordSystem {
                readinessRow(
                    done: probeResult == true,
                    unknown: probeResult == nil,
                    "System audio",
                    probeResult == nil
                        ? "Unknown until it is opened — use Check permission below"
                        : (probeResult == true ? "Allowed" : "Refused — grant it in System Settings")
                )
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.cardCorner))
    }

    private func readinessRow(
        done: Bool, unknown: Bool = false, _ title: String, _ detail: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: unknown
                ? "questionmark.circle"
                : (done ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                .font(.system(size: 12))
                .foregroundStyle(unknown ? Color.secondary : (done ? Color.green : Color.orange))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 110, alignment: .leading)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - API key

    private var apiSection: some View {
        section("Gemini API key", "key") {
            HStack(spacing: 8) {
                SecureField("AIza… or AQ.…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    settings.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    keySaved = true
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            caption(
                keySaved
                    ? "Saved."
                    : "From aistudio.google.com. Stored in a 0600 file in Application Support — never in preferences, never in the log."
            )
            if settings.hasAPIKey {
                Button("Forget key") {
                    settings.clearAPIKey()
                    apiKey = ""
                    keySaved = false
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        section("Audio", "waveform") {
            HStack {
                Text("Microphone").frame(width: 110, alignment: .leading)
                Picker("", selection: $microphoneUID) {
                    Text("System default").tag("")
                    ForEach(AudioDevices.inputDevices()) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .onChange(of: microphoneUID) { _, value in settings.microphoneUID = value }
            }

            if !micGranted {
                warning("QuickMeet has no microphone access yet — macOS will ask on your first recording.")
            }

            if bluetoothSelected {
                warning(
                    "That's a Bluetooth microphone. Opening it switches the headset out of "
                    + "high-quality playback for the whole meeting, so the call will sound worse "
                    + "in your ears. Wired or built-in is better if you have the option."
                )
            }

            Toggle("Record what the Mac is playing", isOn: $recordSystem)
                .onChange(of: recordSystem) { _, value in settings.recordSystemAudio = value }
            caption(
                "The other people in the call. Off makes QuickMeet a plain voice recorder — "
                + "useful for an in-person meeting, where there is no call audio to capture."
            )

            if recordSystem {
                HStack {
                    Text("Capture from").frame(width: 110, alignment: .leading)
                    Picker("", selection: $systemSourceID) {
                        Text("All apps").tag("")
                        ForEach(runningAudioApps, id: \.storedValue) { source in
                            Text(source.label).tag(source.storedValue)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: systemSourceID) { _, value in
                        settings.systemAudioSource = SystemAudioSource.stored(value)
                    }
                }
                caption(
                    "All apps is the reliable choice — a call in a browser tab belongs to the "
                    + "browser, not to the meeting service. Pick one app only if you want to keep "
                    + "everything else out of the recording."
                )

                HStack(spacing: 8) {
                    Button("Check permission") { probeResult = SystemAudioRecorder.probe() }
                        .controlSize(.small)
                    if let probeResult {
                        Label(
                            probeResult ? "System audio is allowed" : "Not allowed yet",
                            systemImage: probeResult ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(probeResult ? Color.secondary : Color.orange)
                    }
                    if probeResult == false {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                            )
                        }
                        .controlSize(.small)
                    }
                }
                caption(
                    "macOS gives no way to read this permission, so the check actually opens a tap. "
                    + "Grant it under Privacy & Security → Screen & System Audio Recording, where "
                    + "QuickMeet appears as audio-only — it never asks for your screen."
                )
            }
        }
    }

    private var bluetoothSelected: Bool {
        microphoneUID.isEmpty
            ? AudioDevices.defaultInputIsBluetooth
            : AudioDevices.isBluetooth(uid: microphoneUID)
    }

    private var runningAudioApps: [SystemAudioSource] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return SystemAudioSource.app(bundleID: id, name: name)
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    // MARK: - Consent

    private var consentSection: some View {
        page {
            Text(ConsentCopy.body)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Remind me before each meeting", isOn: $askEveryTime)
                .onChange(of: askEveryTime) { _, value in settings.askConsentEveryTime = value }
            caption(
                "The reminder carries a sentence you can say out loud and a box for who agreed, "
                + "which is saved with the meeting and included in every export."
            )

            Label(
                "The recording indicator cannot be turned off. QuickMeet has no hidden mode.",
                systemImage: "eye"
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        page {
            HStack {
                Text("Language").frame(width: 110, alignment: .leading)
                TextField("Same as the meeting", text: $notesLanguage)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { settings.notesLanguage = notesLanguage }
            }
            caption(
                "Leave empty and the notes come back in whatever language was spoken. This only "
                + "affects the summary — the transcript is always verbatim, and its language is "
                + "detected per utterance, which is why there is no language setting for it."
            )
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        page {
            Picker("", selection: $retention) {
                ForEach(AudioRetention.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .onChange(of: retention) { _, value in
                settings.retention = value
                store.applyRetention()
            }
            caption(retention.detail)

            HStack(spacing: 8) {
                Text("\(store.meetings.count) meetings · \(formattedBytes) of audio")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.root])
                }
                .controlSize(.small)
            }
        }
    }

    private var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: Int64(store.totalAudioBytes), countStyle: .file)
    }

    // MARK: - Footer

    private var generalSection: some View {
        page {
            Toggle("Global shortcut ⌥⌘R starts and stops a meeting", isOn: $hotkeyEnabled)
                .onChange(of: hotkeyEnabled) { _, value in
                    settings.hotkeyEnabled = value
                    NotificationCenter.default.post(name: .quickMeetHotkeySettingChanged, object: nil)
                }
            caption("Uses a Carbon hot key, which needs no Accessibility or Input Monitoring permission at all.")

            Toggle("Play a sound when recording starts and stops", isOn: $playSound)
                .onChange(of: playSound) { _, value in settings.playSound = value }

            HStack {
                Button("Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Diagnostics.report(), forType: .string)
                }
                .controlSize(.small)
                Button("Open Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.logURL])
                }
                .controlSize(.small)
            }
            caption("The log records device names, byte counts and HTTP errors. Never the API key, never transcript text.")
        }
    }

    // MARK: - Building blocks

    /// A page whose heading is already the sidebar's, so it carries no label of its own.
    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(
        _ title: String,
        _ icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Notification.Name {
    static let quickMeetHotkeySettingChanged = Notification.Name("quickMeetHotkeySettingChanged")
}
