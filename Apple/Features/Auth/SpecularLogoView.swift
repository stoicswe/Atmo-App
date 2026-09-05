import SwiftUI

// MARK: - Specular Logo
/// The app icon's "@" glyph rendered as brushed metal with a specular
/// highlight that sweeps across it on a slow cycle, over the faint
/// radiation ring from the icon. Reduce Motion holds the highlight still.
struct SpecularLogoView: View {
    var size: CGFloat = 104

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One sweep every `cycle` seconds; the highlight is on the move for
    /// the first `sweep` seconds of it and rests off-glyph the remainder.
    private let cycle: Double = 3.8
    private let sweep: Double = 2.0

    var body: some View {
        SwiftUI.TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let progress = reduceMotion ? 0.5 : Self.sweepProgress(
                at: t.truncatingRemainder(dividingBy: cycle), sweep: sweep
            )
            ZStack {
                Image("AtmoRads")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary.opacity(0.07))
                    .frame(width: size * 1.28, height: size * 1.28)

                glyph(progress: progress)
            }
        }
        .frame(width: size * 1.3, height: size * 1.3)
        .accessibilityLabel("Atomic")
    }

    private func glyph(progress: Double) -> some View {
        ZStack {
            // Brushed-metal base: light top, dark belly, light rim.
            LinearGradient(
                stops: [
                    .init(color: Color(white: 0.78), location: 0),
                    .init(color: Color(white: 0.5), location: 0.45),
                    .init(color: Color(white: 0.66), location: 0.7),
                    .init(color: Color(white: 0.42), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Specular band: a soft white streak angled across the glyph,
            // travelling from off-left to off-right each cycle.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.45), location: 0.3),
                    .init(color: .white, location: 0.5),
                    .init(color: .white.opacity(0.45), location: 0.7),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: size * 0.8, height: size * 2)
            .rotationEffect(.degrees(28))
            .offset(x: (progress * 2 - 1) * size * 1.15)
            .blendMode(.plusLighter)

            // A faint accent-tinted glint trailing the streak.
            LinearGradient(
                colors: [.clear, AtmoColors.accent.opacity(0.35), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: size * 0.3, height: size * 2)
            .rotationEffect(.degrees(28))
            .offset(x: (progress * 2 - 1) * size * 1.15 - size * 0.32)
            .blendMode(.plusLighter)
        }
        .frame(width: size, height: size)
        .mask {
            Image("AtmoGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .shadow(color: AtmoColors.accent.opacity(0.28), radius: 22)
    }

    /// 0 → 1 across the sweep window with an ease-in-out, then parked
    /// past the end (off-glyph) until the cycle restarts.
    static func sweepProgress(at time: Double, sweep: Double) -> Double {
        guard time < sweep else { return 1.2 }
        let x = time / sweep
        return x * x * (3 - 2 * x)
    }
}
