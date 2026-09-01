import SwiftUI

/// Shared visual language.
enum Theme {
    /// One colour per speaker, assigned by `SpeakerDirectory.index(of:)` so it is stable
    /// across relaunches and across renames. Index 0 is always the user — a meeting
    /// transcript is read by scanning for your own turns, so yours is the one that has to
    /// be findable at a glance.
    static let speakerColors: [Color] = [
        Color(red: 0.29, green: 0.44, blue: 0.94),   // you — indigo
        Color(red: 0.09, green: 0.64, blue: 0.58),   // teal
        Color(red: 0.90, green: 0.49, blue: 0.13),   // amber
        Color(red: 0.61, green: 0.35, blue: 0.85),   // violet
        Color(red: 0.85, green: 0.30, blue: 0.48),   // rose
        Color(red: 0.24, green: 0.62, blue: 0.28),   // green
        Color(red: 0.20, green: 0.55, blue: 0.78),   // sky
        Color(red: 0.72, green: 0.42, blue: 0.26),   // clay
    ]

    /// - Parameter index: from `SpeakerDirectory.index(of:)` — 0 is the user.
    ///
    /// Remote speakers wrap around the tail of the palette rather than the whole of it, so
    /// a ninth speaker repeats somebody else's colour instead of borrowing the user's.
    static func color(index: Int) -> Color {
        guard index > 0 else { return speakerColors[0] }
        return speakerColors[1 + (index - 1) % (speakerColors.count - 1)]
    }

    static let recordRed = Color(red: 0.90, green: 0.25, blue: 0.24)
    static let cardCorner: CGFloat = 10
}

/// A rounded, quietly filled block. Used for every section of the meeting view so the page
/// reads as a stack of findable things rather than one wall of text.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .textCase(.uppercase)
                        .kerning(0.6)
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.cardCorner))
    }
}

/// A small pill showing a speaker's name in their colour.
struct SpeakerChip: View {
    let name: String
    let color: Color
    var compact = false

    var body: some View {
        Text(name)
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 3)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// The level meter used in the recording HUD.
///
/// A centred symmetric visualiser rather than a scrolling history: every bar reacts to the
/// current level at once, tallest in the middle, so it reads as "this is how loud you are
/// right now". Bar values are pushed from the audio callback, so there is no render timer —
/// nothing here redraws at 60fps for the sake of it.
struct LevelMeter: View {
    var level: Float
    var color: Color
    var barCount = 13

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                let centre = Double(barCount - 1) / 2
                let distance = abs(Double(index) - centre) / centre
                let envelope = pow(cos(distance * .pi / 2), 0.75)
                let height = max(2.5, Double(level) * envelope * 18)

                Capsule()
                    .fill(color.opacity(0.35 + 0.65 * envelope))
                    .frame(width: 2.5, height: height)
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.08), value: level)
    }
}
