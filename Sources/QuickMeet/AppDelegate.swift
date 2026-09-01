import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = MeetingStore()
    private lazy var recorder = MeetingRecorder(store: store)
    private lazy var pipeline = TranscriptionPipeline(store: store)
    private lazy var meetingsWindow = MeetingsWindowController(
        store: store,
        onRetry: { [weak self] id in self?.pipeline.process(id) },
        onToggleRecording: { [weak self] in self?.toggleMeeting() }
    )

    private let consent = ConsentWindowController()
    private let hud = RecordingHUD()
    private let hotkey = Hotkey()

    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    /// Meetings whose finish is still worth a notification. `stopMeeting` adds one and the
    /// store observer posts it — rather than each meeting opening a Combine subscription of
    /// its own, which left a spent `AnyCancellable` in the set for every meeting recorded.
    private var awaitingNotification = Set<UUID>()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.log("QuickMeet launched")

        buildMainMenu()
        buildStatusItem()
        observeRecorder()

        hud.onStop = { [weak self] in self?.stopMeeting() }
        hotkey.onFire = { [weak self] in self?.toggleMeeting() }
        if AppSettings.shared.hotkeyEnabled { hotkey.register() }

        NotificationCenter.default.addObserver(
            forName: .quickMeetHotkeySettingChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                AppSettings.shared.hotkeyEnabled ? self.hotkey.register() : self.hotkey.unregister()
            }
        }

        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // First run: no key means nothing can work, so start where the user has to start.
        if !AppSettings.shared.hasAPIKey {
            meetingsWindow.showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stopping properly finalises both WAV headers. If this is missed — a force quit,
        // a panic — `MeetingStore.recover` patches them on the next launch instead.
        if recorder.isRecording { stopMeeting() }
        hotkey.unregister()
    }

    /// A meeting in progress is worth a confirmation. Quitting mid-recording is almost
    /// always a mistake, and the audio would survive but the meeting would land in the
    /// list as an interrupted one.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder.isRecording else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "A meeting is still recording"
        alert.informativeText = "Stop it and transcribe, or quit and keep the audio for later?"
        alert.addButton(withTitle: "Stop and Transcribe")
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            stopMeeting()
            return .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    // MARK: - Recorder wiring

    private func observeRecorder() {
        // The HUD is driven from the recorder's published state rather than pushed to from
        // the capture callbacks, so there is exactly one source of truth for "are we
        // recording and how loud is it".
        //
        // `objectWillChange` fires *before* the value lands, so delivery has to be deferred
        // — that is what the scheduler is for. `DispatchQueue.main` rather than
        // `RunLoop.main`: a run loop scheduler delivers only in the default mode, so the
        // clock in the menu bar would freeze for as long as a menu was open.
        recorder.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.syncHUD() } }
            .store(in: &cancellables)

        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.meetingsChanged() } }
            .store(in: &cancellables)
    }

    private func syncHUD() {
        if recorder.isRecording {
            hud.show()
            hud.update(
                elapsed: recorder.elapsed,
                micLevel: recorder.micLevel,
                systemLevel: recorder.systemLevel,
                warning: recorder.systemAudioWarning
            )
        } else {
            hud.hide()
        }
        updateStatusTitle()
    }

    /// Meetings are long and people walk away from them, so a transcript finishing is worth
    /// a nudge. By the time this runs the pipeline has already dropped the meeting from its
    /// running set, so `isBusy` is current too.
    private func meetingsChanged() {
        updateStatusTitle()

        for meeting in store.meetings where awaitingNotification.contains(meeting.id) {
            guard meeting.status == .ready || meeting.status == .failed else { continue }
            awaitingNotification.remove(meeting.id)
            post(meeting)
        }
    }

    // MARK: - Main menu

    /// A regular app has a menu bar, and an app that ships without one has no ⌘Q, no ⌘W
    /// and — the part that actually bites — no Cut, Copy or Paste in any of its text
    /// fields, including the one the API key is pasted into.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About QuickMeet", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", #selector(openSettings), key: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide QuickMeet", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit QuickMeet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let meetingItem = NSMenuItem()
        let meetingMenu = NSMenu(title: "Meeting")
        let record = add(meetingMenu, "Record Meeting", #selector(toggleFromMenu), key: "r")
        record.keyEquivalentModifierMask = [.command, .option]
        meetingMenu.addItem(.separator())
        add(meetingMenu, "All Meetings", #selector(openMeetings), key: "0")
        meetingItem.submenu = meetingMenu
        main.addItem(meetingItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// Clicking the Dock icon brings the meetings window back. Closing that window does not
    /// quit QuickMeet — a meeting can be recording with nothing on screen — so without this
    /// the Dock icon would bounce and do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { meetingsWindow.show() }
        return true
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.idleIcon
        item.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        statusItem = item
        updateStatusTitle()
    }

    /// A red dot and a running clock in the menu bar for the whole recording.
    ///
    /// Deliberately redundant with the HUD: the HUD can be dragged to a corner of another
    /// display, and the menu bar is the one place that is always in the user's line of
    /// sight. Between the two there is no realistic way to be recording without knowing it.
    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }

        if recorder.isRecording {
            // Recording keeps the filled red dot rather than the logo. The one thing the
            // menu bar has to say while a meeting runs is *that a meeting is running*, and
            // a red circle says it from across the room; a monochrome app mark does not.
            button.image = NSImage(
                systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording"
            )
            button.title = " \(Meeting.formatted(duration: recorder.elapsed))"
            button.contentTintColor = .systemRed
        } else if pipeline.isBusy {
            button.image = Self.idleIcon
            button.title = " ···"
            button.contentTintColor = nil
        } else {
            button.image = Self.idleIcon
            button.title = ""
            button.contentTintColor = nil
        }
    }

    /// The app's own mark, as a template so it inverts with the menu bar. Falls back to the
    /// old symbol if `Logo.png` is missing from the bundle — a menu bar item with no image
    /// is an invisible one, and this is the only way into the app.
    private static let idleIcon: NSImage? = {
        if let icon = Branding.statusIcon {
            icon.accessibilityDescription = "QuickMeet"
            return icon
        }
        return NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "QuickMeet")
    }()

    /// The menu is rebuilt when it opens rather than kept in sync from elsewhere.
    /// Permissions change outside the app, meetings finish in the background, and reading
    /// the state at open time keeps all of it correct with no cross-wiring.
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        if recorder.isRecording {
            add(menu, "Stop Recording  (\(Meeting.formatted(duration: recorder.elapsed)))", #selector(stopFromMenu))
        } else {
            let item = add(menu, "Record Meeting", #selector(startFromMenu), key: "r")
            item.keyEquivalentModifierMask = [.command, .option]
            if !AppSettings.shared.hasAPIKey {
                item.isEnabled = false
                add(menu, "Add your Gemini API key first", #selector(openSettings)).isEnabled = true
            }
        }

        menu.addItem(.separator())

        let recent = store.meetings.prefix(5)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No meetings yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for meeting in recent {
                let title = meeting.status == .processing
                    ? "\(meeting.displayTitle)  ·  \(meeting.progress)"
                    : meeting.displayTitle
                let item = add(menu, title, #selector(openMeeting(_:)))
                item.representedObject = meeting.id
                item.indentationLevel = 1
            }
        }

        add(menu, "All Meetings…", #selector(openMeetings))
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), key: ",")
        add(menu, "Copy Diagnostics", #selector(copyDiagnostics))
        menu.addItem(.separator())
        add(menu, "Quit QuickMeet", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(
        _ menu: NSMenu, _ title: String, _ action: Selector, key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func startFromMenu() { startMeeting() }
    @objc private func toggleFromMenu() { toggleMeeting() }
    @objc private func stopFromMenu() { stopMeeting() }
    @objc private func openMeetings() { meetingsWindow.show() }
    @objc private func openSettings() { meetingsWindow.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openMeeting(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        meetingsWindow.show(selecting: id)
    }

    @objc private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.report(), forType: .string)
    }

    private func toggleMeeting() {
        recorder.isRecording ? stopMeeting() : startMeeting()
    }

    // MARK: - The recording flow

    /// Gate order matters: key, then consent, then microphone.
    ///
    /// The microphone prompt is left until last on purpose. Asking macOS for the microphone
    /// and *then* showing a consent screen the user might cancel would leave them having
    /// granted a permission for something that never happened.
    private func startMeeting() {
        guard !recorder.isRecording else { return }

        guard AppSettings.shared.hasAPIKey else {
            meetingsWindow.showSettings()
            return
        }

        guard AppSettings.shared.consentAcknowledged else {
            consent.showFirstRun { [weak self] in self?.startMeeting() }
            return
        }

        guard !AppSettings.shared.askConsentEveryTime else {
            consent.showPreRecording { [weak self] record in
                self?.beginRecording(consent: record)
            }
            return
        }

        // The reminder is off, but the acknowledgement still stands and is recorded as
        // such — the user said once that they take responsibility for asking.
        beginRecording(
            consent: ConsentRecord(acknowledged: true, acknowledgedAt: Date(), note: "")
        )
    }

    private func beginRecording(consent record: ConsentRecord) {
        MicRecorder.requestMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.alert(
                    "QuickMeet needs the microphone",
                    "Allow it under Privacy & Security → Microphone, then try again."
                )
                return
            }

            do {
                try self.recorder.start(consent: record)
                self.syncHUD()
            } catch {
                self.alert("Couldn't start recording", error.localizedDescription)
            }
        }
    }

    private func stopMeeting() {
        guard let id = recorder.stop() else { return }
        syncHUD()
        awaitingNotification.insert(id)
        pipeline.process(id)
    }

    private func post(_ meeting: Meeting) {
        let content = UNMutableNotificationContent()
        if meeting.status == .ready {
            content.title = meeting.displayTitle
            let actions = meeting.notes?.actionItems.count ?? 0
            content.body = actions > 0
                ? "Notes ready · \(actions) action item\(actions == 1 ? "" : "s")"
                : "Notes ready"
        } else {
            content.title = "Meeting couldn't be transcribed"
            content.body = meeting.errorMessage ?? "Open QuickMeet to retry."
        }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: meeting.id.uuidString, content: content, trigger: nil
            )
        )
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
