import SwiftUI
import AtmoCore

// MARK: - Vault Lock Toast
/// Glass capsule at the top of the shell announcing that the Vault
/// re-locked on its own — the unlock timer ran out, or the app was left.
/// Shows for a few seconds of *foreground* time (a lock that happened in
/// the background is announced when the person comes back), and a tap
/// dismisses it early. Manual locks stay silent.
struct VaultLockToast: View {
    private let lock = VaultLock.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let notice = lock.autoLockNotice {
                HStack(spacing: AtmoTheme.Spacing.sm) {
                    Image(systemName: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(AtmoColors.accent)
                    Text(notice.message)
                        .font(.caption.weight(.medium))
                        .lineLimit(2)
                }
                .padding(.horizontal, AtmoTheme.Spacing.md)
                .padding(.vertical, AtmoTheme.Spacing.sm)
                .glassEffect(.regular, in: Capsule())
                .padding(.horizontal, AtmoTheme.Spacing.xl)
                .contentShape(Capsule())
                .onTapGesture { lock.dismissAutoLockNotice() }
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: lock.autoLockNotice)
        // Count down only while on screen; restarts if the app comes back.
        .task(id: "\(String(describing: lock.autoLockNotice))|\(scenePhase == .active)") {
            guard lock.autoLockNotice != nil, scenePhase == .active else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            lock.dismissAutoLockNotice()
        }
    }
}
