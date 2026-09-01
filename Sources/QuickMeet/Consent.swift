import AppKit
import SwiftUI

/// The consent surfaces.
///
/// This is the part of the app that has no technical reason to exist and the strongest
/// product reason to. Recording a meeting is the one thing QuickMeet does, and in a great
/// many places doing it without telling the other people is a criminal offence rather than
/// a faux pas — §201 StGB across Germany, all-party consent in roughly a dozen US states.
/// An app that makes it one click to record and zero clicks to think about that is an app
/// that gets its users in trouble.
///
/// So there are four surfaces, and they are deliberately different in weight:
///
///  1. **A first-run acknowledgement.** Once, before the first recording. It states the
///     legal position plainly and asks the user to accept that it is theirs to manage.
///  2. **A pre-recording reminder** with a phrase to say out loud and a place to record
///     who agreed. Can be turned off; the setting to turn it off says what it is for.
///  3. **A recording indicator that cannot be hidden** — see `RecordingHUD`. There is no
///     stealth mode and there will not be one.
///  4. **The consent state stored on the meeting** and carried into every export.
enum ConsentCopy {
    static let headline = "Everyone in the room needs to know"

    static let body = """
    QuickMeet records your microphone and the audio your Mac is playing, and sends both to \
    Google Gemini to be transcribed.

    In much of the world, recording a conversation without the agreement of everyone in it \
    is a criminal offence, not a courtesy. In Germany that is §201 StGB — up to three years. \
    Around a dozen US states require all-party consent. Many workplaces require the works \
    council to be involved before a tool like this is used at all.

    QuickMeet cannot tell where you are or who is on the call, so this part is yours.
    """

    static let acknowledgement = "I'll get everyone's agreement before I record them."

    /// Something to actually say. The single most useful thing this screen can offer is
    /// the sentence itself — the reason people skip asking is rarely principle, it is not
    /// knowing how to raise it without making it awkward.
    ///
    /// One sentence, in English. Translations were tried and dropped: a second language
    /// doubles the height of the screen for a phrase most users will never say, and the
    /// wording is meant to be adapted anyway.
    static let phrase =
        "Before we start — I'd like to record this and get an automatic summary. "
        + "Is that alright with everyone?"

    static let headphonesHint =
        "Wearing headphones gives a noticeably better transcript — otherwise your microphone "
        + "picks up the call as well and both sides land on one track."
}

// MARK: - First run

struct FirstRunConsentView: View {
    var onAccept: () -> Void
    var onCancel: () -> Void

    @State private var accepted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.recordRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ConsentCopy.headline)
                        .font(.system(size: 17, weight: .semibold))
                    Text("One-time setup")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 16)

            Text(ConsentCopy.body)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

            Toggle(isOn: $accepted) {
                Text(ConsentCopy.acknowledgement)
                    .font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.checkbox)
            .padding(.bottom, 18)

            HStack {
                Spacer()
                Button("Not now", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: onAccept)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!accepted)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

// MARK: - Before each recording

struct PreRecordingConsentView: View {
    var onStart: (ConsentRecord) -> Void
    var onCancel: () -> Void

    @State private var note = ""
    @State private var dontAskAgain = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Theme.recordRed)
                    .frame(width: 11, height: 11)
                Text("Ready to record")
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.bottom, 4)

            Text("Ask the room before you start. Something like:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            HStack(alignment: .top, spacing: 8) {
                Text(ConsentCopy.phrase)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ConsentCopy.phrase, forType: .string)
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            .padding(10)
            .background(
                Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 5) {
                Text("Who agreed? (optional, saved with the meeting)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("e.g. Anna and Ben, on the call", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            .padding(.bottom, 12)

            Label(ConsentCopy.headphonesHint, systemImage: "headphones")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            Toggle("Don't remind me before each meeting", isOn: $dontAskAgain)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .padding(.bottom, 16)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Everyone agreed — Record") {
                    if dontAskAgain { AppSettings.shared.askConsentEveryTime = false }
                    onStart(
                        ConsentRecord(
                            acknowledged: true,
                            acknowledgedAt: Date(),
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
    }
}

// MARK: - Window plumbing

/// Presents the consent windows.
///
/// These are real windows rather than sheets on the meetings window: recording is started
/// from the menu bar and from ⌥⌘R as often as from the window, and a sheet would have to
/// summon its host first. `NSApp.activate` is called deliberately — unlike the recording
/// HUD, this one *should* take focus: it is asking a question.
@MainActor
final class ConsentWindowController {
    private var window: NSWindow?

    func showFirstRun(onAccept: @escaping () -> Void) {
        present(
            title: "Before your first recording",
            view: AnyView(
                FirstRunConsentView(
                    onAccept: { [weak self] in
                        AppSettings.shared.consentAcknowledged = true
                        self?.close()
                        onAccept()
                    },
                    onCancel: { [weak self] in self?.close() }
                )
            )
        )
    }

    func showPreRecording(onStart: @escaping (ConsentRecord) -> Void) {
        present(
            title: "Record meeting",
            view: AnyView(
                PreRecordingConsentView(
                    onStart: { [weak self] record in
                        self?.close()
                        onStart(record)
                    },
                    onCancel: { [weak self] in self?.close() }
                )
            )
        )
    }

    private func present(title: String, view: AnyView) {
        close()

        // `sizingOptions` is deliberately left at its default here.
        //
        // Setting it to `[]` — which is the right move for a window whose *content* would
        // otherwise dictate an absurd height, like a bare `TextEditor` — makes
        // `fittingSize` report (0, 0). A window built from that is 0×0: created, ordered
        // front, focused, and completely invisible. Clicking "Record Meeting" appeared to
        // do nothing at all. Measured: (0, 0) with the flag, (460, 348) without it.
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()

        var size = hosting.fittingSize
        // Belt and braces: never build a window too small to see, whatever SwiftUI says.
        size.width = max(size.width, 380)
        size.height = max(size.height, 200)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Diagnostics.log("presented consent window '\(title)' size=\(Int(size.width))x\(Int(size.height))")
    }

    private func close() {
        window?.orderOut(nil)
        window = nil
    }
}
