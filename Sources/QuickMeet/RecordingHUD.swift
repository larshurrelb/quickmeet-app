import AppKit
import SwiftUI

/// The floating indicator shown for the whole length of a recording.
///
/// **There is no way to hide this, and that is a feature.** An app that records other
/// people should be visibly recording them; a hidden-indicator mode is the difference
/// between a note-taker and a bug, both legally and in how it reads to the people in the
/// room. The panel can be dragged out of the way and that is all.
///
/// Like QuickTalk's pill it is an `NSPanel` with `.nonactivatingPanel`, so it floats over
/// every app — including full-screen ones, which is where a video call usually is —
/// without stealing focus from the call.
@MainActor
final class RecordingHUD {
    private var panel: NSPanel?
    private var host: NSHostingView<RecordingHUDView>?
    private let model = RecordingHUDModel()

    var onStop: (() -> Void)?

    func show() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Draggable by its whole surface: the one accommodation a permanent overlay owes
        // the user is getting out of the way of what is underneath it.
        panel.isMovableByWindowBackground = true

        let view = RecordingHUDView(model: model, onStop: { [weak self] in self?.onStop?() })
        // Default `sizingOptions`, because `resizeToFit` below asks this view how big it
        // wants to be. Clearing them zeroes `fittingSize`, and the HUD would collapse to
        // its minimum and clip — the same mistake that made the consent window invisible.
        let host = NSHostingView(rootView: view)
        panel.contentView = host

        self.panel = panel
        self.host = host
        resizeToFit()
        position()
        panel.orderFrontRegardless()
    }

    func update(elapsed: TimeInterval, micLevel: Float, systemLevel: Float, warning: String?) {
        let changedWarning = model.warning != warning
        model.elapsed = elapsed
        model.micLevel = micLevel
        model.systemLevel = systemLevel
        model.warning = warning
        // Only the warning changes the panel's height; resizing on every level update
        // would fight the drag.
        if changedWarning {
            DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        host = nil
    }

    /// Ask SwiftUI how big it wants to be and match the panel to it, keeping the panel's
    /// top-left corner where the user dragged it.
    private func resizeToFit() {
        guard let panel, let host else { return }
        host.layoutSubtreeIfNeeded()

        var size = host.fittingSize
        size.width = max(size.width, 240)
        size.height = max(size.height, 64)

        let frame = panel.frame
        panel.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        panel.setFrameOrigin(NSPoint(x: frame.minX, y: frame.maxY - panel.frame.height))
    }

    /// Top centre, tucked under the notch.
    ///
    /// `visibleFrame` already excludes the menu bar, and on a notched MacBook the notch
    /// lives inside that menu bar — so the top of the visible frame *is* the underside of
    /// the notch, on notched and un-notched displays alike. The panel's top edge goes
    /// flush with it and the view's own outer padding supplies the visual gap, which also
    /// keeps the glass from being clipped by the panel bounds.
    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: (visible.midX - panel.frame.width / 2).rounded(),
                y: visible.maxY - panel.frame.height
            )
        )
    }
}

@MainActor
final class RecordingHUDModel: ObservableObject {
    @Published var elapsed: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var warning: String?
}

struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel
    var onStop: () -> Void

    @State private var pulse = false

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .modifier(GlassPanel())
            // Outer padding, outside the glass: it is both the gap below the notch and the
            // room the shadow needs inside the panel's bounds.
            .padding(10)
            .onAppear { pulse = true }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Theme.recordRed)
                    .frame(width: 9, height: 9)
                    .opacity(pulse ? 0.3 : 1)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)

                Text(Meeting.formatted(duration: model.elapsed))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    // .primary, never white — glass takes on whatever is behind it, and a
                    // fixed white is unreadable over a light window.
                    .foregroundStyle(.primary)

                Spacer(minLength: 14)

                StopButton(action: onStop)
            }

            HStack(spacing: 14) {
                meter("You", level: model.micLevel, color: Theme.speakerColors[0])
                meter("Others", level: model.systemLevel, color: Theme.speakerColors[1])
            }

            if let warning = model.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 240, alignment: .leading)
            }
        }
    }

    private func meter(_ label: String, level: Float, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            LevelMeter(level: level, color: color)
        }
    }

}

/// The glass itself.
///
/// Applied **to the content**, not placed behind it with `.background(Color.clear
/// .glassEffect(…))`. That earlier form renders a washed-out approximation: the effect
/// needs to own the view it is shaping, or it has nothing to refract.
private struct GlassPanel: ViewModifier {
    private static let corner: CGFloat = 22

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: Self.corner, style: .continuous))
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        }
    }
}

/// Stop, as its own glass element on macOS 26 so it reads as a control sitting *on* the
/// panel rather than text printed into it.
private struct StopButton: View {
    var action: () -> Void

    var body: some View {
        if #available(macOS 26, *) {
            button.buttonStyle(.glass).tint(Theme.recordRed)
        } else {
            button.buttonStyle(.borderless).foregroundStyle(Theme.recordRed)
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill").font(.system(size: 9))
                Text("Stop").font(.system(size: 12, weight: .medium))
            }
        }
    }
}
