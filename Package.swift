// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickMeet",
    // Core Audio process taps (AudioHardwareCreateProcessTap) land in 14.2, but the
    // audio-only "System Audio Recording" permission — the whole reason for using taps
    // instead of ScreenCaptureKit — is 14.4. Requiring less would mean shipping a build
    // that asks for screen recording on some Macs and not others.
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "QuickMeet",
            path: "Sources/QuickMeet"
        )
    ]
)
