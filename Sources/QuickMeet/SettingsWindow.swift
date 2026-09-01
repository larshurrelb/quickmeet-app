import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private var hosting: NSHostingView<SettingsView>?
    private let store: MeetingStore

    init(store: MeetingStore) {
        self.store = store
    }

    func show() {
        if window == nil { build() }
        reloadIfVisible()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The SwiftUI view seeds its `@State` at construction, so anything changed from the
    /// status menu while Settings is open has to be pushed in from this side. The menu
    /// reads its own state when it opens; this is the other direction.
    func reloadIfVisible() {
        guard let hosting else { return }
        hosting.rootView = SettingsView(store: store)
    }

    private func build() {
        let hosting = NSHostingView(rootView: SettingsView(store: store))
        hosting.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "QuickMeet Settings"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        self.hosting = hosting
    }
}

struct SettingsView: View {
    @ObservedObject var store: MeetingStore

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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                apiSection
                Divider()
                audioSection
                Divider()
                consentSection
                Divider()
                notesSection
                Divider()
                storageSection
                Divider()
                footer
            }
            .padding(22)
        }
        .frame(width: 520, height: 640)
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
        section("Consent", "person.2.wave.2") {
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
        section("Notes", "text.append") {
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
        section("Recordings", "internaldrive") {
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

    private var footer: some View {
        section("General", "gearshape") {
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
