import Foundation

// MARK: - System audio source

/// What the process tap should capture.
enum SystemAudioSource: Equatable {
    /// Everything the Mac plays, minus QuickMeet itself. The reliable default: a call in
    /// a browser tab, a native Zoom window and a Teams window all work without the user
    /// having to know which process owns the audio.
    case allApps
    /// One application, by bundle identifier. Cleaner — the music you left playing stays
    /// out of the transcript — but it only helps when the meeting really lives in one
    /// process, which is not true for anything running in a browser.
    case app(bundleID: String, name: String)

    var label: String {
        switch self {
        case .allApps: return "All apps"
        case let .app(_, name): return name
        }
    }

    var storedValue: String {
        switch self {
        case .allApps: return ""
        case let .app(bundleID, name): return "\(bundleID)\u{1F}\(name)"
        }
    }

    static func stored(_ raw: String?) -> SystemAudioSource {
        guard let raw, !raw.isEmpty else { return .allApps }
        let parts = raw.components(separatedBy: "\u{1F}")
        guard parts.count == 2, !parts[0].isEmpty else { return .allApps }
        return .app(bundleID: parts[0], name: parts[1])
    }
}

// MARK: - Audio retention

/// How long the recorded audio survives after a transcript exists.
///
/// This is a privacy control, not a disk-space one. The transcript is the thing the user
/// wanted; the audio is a recording of other people's voices, and keeping it forever by
/// default is the wrong posture for an app whose whole risk surface is other people's
/// voices.
enum AudioRetention: String, CaseIterable, Identifiable {
    case deleteAfterTranscript
    case keepSevenDays
    case keepForever

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deleteAfterTranscript: return "Delete once transcribed"
        case .keepSevenDays: return "Keep for 7 days"
        case .keepForever: return "Keep until I delete it"
        }
    }

    var detail: String {
        switch self {
        case .deleteAfterTranscript:
            return "The safest default. The transcript stays; the voices do not."
        case .keepSevenDays:
            return "Long enough to re-run a transcript that came back wrong."
        case .keepForever:
            return "Audio stays on this Mac until you delete the meeting."
        }
    }

    var days: Int? {
        switch self {
        case .deleteAfterTranscript: return 0
        case .keepSevenDays: return 7
        case .keepForever: return nil
        }
    }
}

// MARK: - Settings

/// Preferences live in UserDefaults; the API key lives in its own `0600` file and never
/// touches defaults, logs, or disk in plain text.
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let microphone = "microphoneUID"
        static let systemSource = "systemAudioSource"
        static let recordSystemAudio = "recordSystemAudio"
        static let retention = "audioRetention"
        static let consentAcknowledged = "consentAcknowledged"
        static let askConsentEveryTime = "askConsentEveryTime"
        static let notesLanguage = "notesLanguage"
        static let playSound = "playSound"
        static let hotkeyEnabled = "hotkeyEnabled"
    }

    /// CoreAudio device UID, or empty for "follow the system default".
    var microphoneUID: String {
        get { defaults.string(forKey: Key.microphone) ?? "" }
        set { defaults.set(newValue, forKey: Key.microphone) }
    }

    var systemAudioSource: SystemAudioSource {
        get { SystemAudioSource.stored(defaults.string(forKey: Key.systemSource)) }
        set { defaults.set(newValue.storedValue, forKey: Key.systemSource) }
    }

    /// Off turns QuickMeet into a plain voice recorder — useful for an in-person meeting
    /// where there is no call audio to capture, and the honest thing to offer someone who
    /// does not want to grant the system audio permission at all.
    var recordSystemAudio: Bool {
        get { defaults.object(forKey: Key.recordSystemAudio) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.recordSystemAudio) }
    }

    var retention: AudioRetention {
        get { AudioRetention(rawValue: defaults.string(forKey: Key.retention) ?? "") ?? .keepSevenDays }
        set { defaults.set(newValue.rawValue, forKey: Key.retention) }
    }

    /// Set once, on the first run, after the user reads what recording other people means.
    /// Recording is refused until it is true — see `ConsentGate`.
    var consentAcknowledged: Bool {
        get { defaults.bool(forKey: Key.consentAcknowledged) }
        set { defaults.set(newValue, forKey: Key.consentAcknowledged) }
    }

    /// The per-recording reminder. Defaults to on, and the wording is deliberately a
    /// question about the room rather than a licence agreement.
    var askConsentEveryTime: Bool {
        get { defaults.object(forKey: Key.askConsentEveryTime) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.askConsentEveryTime) }
    }

    /// Empty means "whatever language the meeting was in". Notes are the one place a
    /// language choice is safe: it is a prompt to a normal model, not the transcribe
    /// model, so it cannot silently disable anything.
    var notesLanguage: String {
        get { defaults.string(forKey: Key.notesLanguage) ?? "" }
        set { defaults.set(newValue, forKey: Key.notesLanguage) }
    }

    var playSound: Bool {
        get { defaults.object(forKey: Key.playSound) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.playSound) }
    }

    var hotkeyEnabled: Bool {
        get { defaults.object(forKey: Key.hotkeyEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.hotkeyEnabled) }
    }

    var apiKey: String {
        get { KeyStore.read() ?? "" }
        set { KeyStore.write(newValue) }
    }

    var hasAPIKey: Bool { KeyStore.read() != nil }

    func clearAPIKey() { KeyStore.clear() }
}

// MARK: - Key storage

/// The Gemini API key, in a file only your account can read.
///
/// **Not the Keychain.** On the file-based macOS keychain, access is granted per code
/// signature, so any build whose signature differs from the one that stored the item
/// raises a password overlay — which is every build when signing ad-hoc. Contributors
/// build ad-hoc, so that is a wall of dialogs for them.
///
/// **Not `UserDefaults`.** That puts a credential somewhere
/// `defaults read com.quickmeet.QuickMeet` will print in full — a genuine leak the moment
/// anyone pastes their settings into a bug report.
///
/// What this gives you, stated plainly:
///
///  * mode `0600` in a `0700` directory — no other account on this Mac can read it
///  * outside the preferences domain, so no `defaults read` ever prints it
///  * excluded from Time Machine, so it does not spread into backups
///  * encrypted at rest by FileVault, if FileVault is on
///  * never logged — and `Diagnostics` redacts anything key-shaped as a backstop
///
/// What it does **not** give you: protection from other software running as *you*. No
/// local store does. If that stops being true, revoke the key at aistudio.google.com —
/// that takes a second and is the only real remedy.
enum KeyStore {
    private static let lock = NSLock()
    /// `nil` means "not read yet"; `.some(nil)` means "read, and there is no key".
    private static var cached: String??

    private static var directory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickMeet", isDirectory: true)
    }

    private static var fileURL: URL {
        directory.appendingPathComponent("gemini-api-key")
    }

    static func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let value = (try? String(contentsOf: fileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        cached = .some((value?.isEmpty == false) ? value : nil)
        return cached ?? nil
    }

    static func write(_ value: String) {
        lock.lock()
        defer { lock.unlock() }

        guard !value.isEmpty else {
            purge()
            cached = .some(nil)
            return
        }
        store(value)
        cached = .some(value)
    }

    /// Forgets the key entirely — Settings offers this so a machine can be handed on
    /// without leaving a credential behind.
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        purge()
        cached = .some(nil)
    }

    // MARK: - Disk

    private static func store(_ value: String) {
        let manager = FileManager.default

        // 0700: the directory itself is not listable by anyone else either.
        try? manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // createFile applies the permissions as the file is created, so there is never an
        // instant where the key exists as a world-readable file. Writing "atomically"
        // would rename a temp file into place and take the umask's permissions instead.
        try? manager.removeItem(at: fileURL)
        let created = manager.createFile(
            atPath: fileURL.path,
            contents: Data(value.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            // Only ever the fact of failure — never the value.
            Diagnostics.recordError("could not write the API key file")
            return
        }

        // Keep the credential out of Time Machine snapshots.
        var url = fileURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? url.setResourceValues(resourceValues)
    }

    private static func purge() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
