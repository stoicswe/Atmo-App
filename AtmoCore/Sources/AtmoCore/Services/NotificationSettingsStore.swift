import Foundation
import Observation

// MARK: - NotificationSettingsStore
// What the user wants to be notified about:
//   • interactions on their own content (like/reply/mention/repost/quote/
//     follow), individually toggleable behind a master switch, and
//   • per-account post subscriptions set from other users' profile pages.
// Persisted in UserDefaults; read by BackgroundSyncEngine on every pass.
@Observable
@MainActor
public final class NotificationSettingsStore {

    public static let shared = NotificationSettingsStore()

    /// The interaction kinds that can trigger a notification.
    public static let notifiableReasons: [NotificationItem.NotificationReason] =
        [.like, .reply, .mention, .repost, .quote, .follow]

    // MARK: - State
    public private(set) var interactionsEnabled: Bool
    public private(set) var enabledReasons: Set<String>
    public private(set) var subscriptions: [UserNotificationSubscription]

    // MARK: - Private
    private let defaults: UserDefaults
    private let enabledKey = "atmo.notify.interactionsEnabled"
    private let reasonsKey = "atmo.notify.enabledReasons"
    private let subscriptionsKey = "atmo.notify.subscriptions"

    /// Internal so tests can point the store at a scratch suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.interactionsEnabled = defaults.object(forKey: enabledKey) as? Bool ?? false
        if let stored = defaults.stringArray(forKey: reasonsKey) {
            self.enabledReasons = Set(stored)
        } else {
            // Default: every typical interaction kind, active once the
            // master switch is turned on.
            self.enabledReasons = Set(Self.notifiableReasons.map(\.rawValue))
        }
        if let data = defaults.data(forKey: subscriptionsKey),
           let decoded = try? JSONDecoder().decode([UserNotificationSubscription].self, from: data) {
            self.subscriptions = decoded
        } else {
            self.subscriptions = []
        }
    }

    // MARK: - Interaction kinds

    public func setInteractionsEnabled(_ enabled: Bool) {
        interactionsEnabled = enabled
        defaults.set(enabled, forKey: enabledKey)
    }

    public func isReasonEnabled(_ reason: NotificationItem.NotificationReason) -> Bool {
        enabledReasons.contains(reason.rawValue)
    }

    public func setReason(_ reason: NotificationItem.NotificationReason, enabled: Bool) {
        if enabled {
            enabledReasons.insert(reason.rawValue)
        } else {
            enabledReasons.remove(reason.rawValue)
        }
        defaults.set(Array(enabledReasons).sorted(), forKey: reasonsKey)
    }

    // MARK: - Per-user subscriptions

    public func subscription(for did: String) -> UserNotificationSubscription? {
        subscriptions.first { $0.did == did }
    }

    /// Sets (or clears, for `.off`) the post-notification mode for an account.
    public func setSubscription(
        did: String,
        handle: String,
        displayName: String?,
        mode: UserPostNotificationMode
    ) {
        subscriptions.removeAll { $0.did == did }
        if mode != .off {
            subscriptions.append(
                UserNotificationSubscription(did: did, handle: handle, displayName: displayName, mode: mode)
            )
        }
        persistSubscriptions()
    }

    public func removeSubscription(did: String) {
        subscriptions.removeAll { $0.did == did }
        persistSubscriptions()
    }

    private func persistSubscriptions() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        defaults.set(data, forKey: subscriptionsKey)
    }
}
