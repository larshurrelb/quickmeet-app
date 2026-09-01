import AppKit

// `.regular`: QuickMeet is in the Dock and the ⌘-Tab switcher, alongside its menu bar item.
// It was an accessory app for a while, which kept it out of both — and made the meetings
// window hard to get back to once it was closed, since the only door was a small icon in
// the menu bar. A regular app needs a main menu; `AppDelegate` builds one.
let app = NSApplication.shared

// Top-level code is nonisolated, but it does run on the main thread — and AppDelegate is
// @MainActor because every part of it touches AppKit.
let delegate = MainActor.assumeIsolated { AppDelegate() }

app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
