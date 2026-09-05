import SwiftUI
import Combine
import AtmoCore

// MARK: - Ghost Badge
/// The marker on a ghost post: a small glass pill with the time it has
/// left. Ticks every minute while on screen.
struct GhostBadge: View {
    let post: PostItem
    @State private var now = Date()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        if GhostPostPolicy.isGhost(post) {
            HStack(spacing: 3) {
                Image(systemName: "moon.haze.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(GhostPostPolicy.remainingText(until: GhostPostPolicy.expiresAt(post), now: now))
                    .font(.system(size: 10, weight: .semibold))
                    .fixedSize()
            }
            .foregroundStyle(AtmoColors.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: Capsule())
            .onReceive(clock) { now = $0 }
            .accessibilityLabel("Ghost post, \(GhostPostPolicy.remainingText(until: GhostPostPolicy.expiresAt(post), now: now))")
        }
    }
}
