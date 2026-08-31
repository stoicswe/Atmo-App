import SwiftUI

// MARK: - Haptics
// Centralized haptic vocabulary for the app. Calls are no-ops on platforms
// without a Taptic Engine (macOS), so call sites need no conditionals.
#if os(iOS)
import UIKit

@MainActor
enum Haptics {
    /// Light tap for pressing a control (tab buttons, menu rows, FABs).
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Subtle, soft pulse — used as the side menu slides in.
    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6)
    }

    /// Reused generator for the pull-to-refresh texture — kept warm so the
    /// rapid ticks fire with minimal latency.
    private static let pullGenerator = UIImpactFeedbackGenerator(style: .soft)

    /// One tick of the rough-surface ratchet while pulling to refresh —
    /// faint at first, firmer as the pull nears the trigger point.
    static func pullTick(progress: Double) {
        let clamped = max(0, min(1, progress))
        pullGenerator.impactOccurred(intensity: 0.25 + 0.55 * clamped)
        pullGenerator.prepare()
    }

    /// Firm tap confirming an action engaged (the refresh is happening).
    static func confirm() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// Heavy thump: the pull-to-refresh is fully wound — releasing here
    /// will trigger the refresh.
    static func thump() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1.0)
    }

    /// Heartbeat "lub-dub" for liking a post: a firm beat followed by a
    /// lighter echo.
    static func heartbeat() {
        Task { @MainActor in
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred(intensity: 0.9)
            try? await Task.sleep(for: .milliseconds(120))
            generator.impactOccurred(intensity: 0.55)
        }
    }

    /// Celebratory triple-tap: three quick, rising light impacts.
    /// Fired when a post submits successfully.
    static func celebrate() {
        Task { @MainActor in
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred(intensity: 0.7)
            try? await Task.sleep(for: .milliseconds(110))
            generator.impactOccurred(intensity: 0.85)
            try? await Task.sleep(for: .milliseconds(110))
            generator.impactOccurred(intensity: 1.0)
        }
    }
}
#else
@MainActor
enum Haptics {
    static func tap() {}
    static func soft() {}
    static func pullTick(progress: Double) {}
    static func confirm() {}
    static func thump() {}
    static func heartbeat() {}
    static func celebrate() {}
}
#endif
