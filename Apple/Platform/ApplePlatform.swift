import Foundation
import ATProtoKit
import AtmoCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#elseif os(watchOS)
import WatchKit
#endif

/// The Apple-platform implementation bundle for AtmoCore's seams.
/// Installed once, before any AtmoCore service is touched:
///
///     init() { Atmo.platform = .apple }   // in the App struct
extension AtmoPlatform {

    static var apple: AtmoPlatform {
        AtmoPlatform(
            secrets: KeychainSecretsStore(),
            syncedKeyValue: syncedKeyValueStore,
            postIndexer: postIndexer,
            // ATProtoKit's own Keychain-backed store. The default service
            // name ("ATProtoKit") is deliberately preserved so refresh
            // tokens stored by ATProtoKit 0.32.x remain readable after the
            // 0.34 credential-storage migration.
            makeCredentialStore: { AppleSecureKeychain() },
            foregroundNotification: foregroundNotification,
            backgroundNotification: backgroundNotification,
            timelineRefreshInterval: timelineRefreshInterval,
            alertPresenter: UserNotificationsPresenter()
        )
    }

    // iCloud KVS needs the ubiquity-kvstore entitlement. The watch app
    // ships without one (see project.yml), so it uses local storage
    // instead of making iCloud calls that would silently no-op.
    private static var syncedKeyValueStore: any SyncedKeyValueStore {
#if os(watchOS)
        LocalKeyValueStore()
#else
        UbiquitousKeyValueStore()
#endif
    }

    private static var postIndexer: any PostIndexing {
#if canImport(CoreSpotlight)
        SpotlightPostIndexer()
#else
        NoopPostIndexer()
#endif
    }

    private static var foregroundNotification: Notification.Name {
#if os(iOS)
        UIApplication.didBecomeActiveNotification
#elseif os(macOS)
        NSApplication.didBecomeActiveNotification
#else
        WKApplication.didBecomeActiveNotification
#endif
    }

    // While the app is away from the foreground, in-app poll timers stop
    // (battery); freshness is handed to BackgroundSync's system-coalesced
    // schedulers instead.
    //
    // macOS: "resigned active" is NOT away — it fires the moment the user
    // clicks any other app's window while Atmo stays fully visible, which
    // silently killed the timeline auto-refresh for whole desktop
    // sessions. Only an actually-hidden app (⌘H) pauses the poll; the
    // didBecomeActive resume brings it back on the next click into Atmo.
    private static var backgroundNotification: Notification.Name {
#if os(iOS)
        UIApplication.didEnterBackgroundNotification
#elseif os(macOS)
        NSApplication.didHideNotification
#else
        WKApplication.didEnterBackgroundNotification
#endif
    }

    // macOS users are typically plugged in and expect fresher content.
    // iOS and watchOS respect battery by refreshing less aggressively.
    private static var timelineRefreshInterval: TimeInterval {
#if os(macOS)
        60          // 1 minute on macOS
#else
        3 * 60      // 3 minutes on iOS/iPadOS/watchOS
#endif
    }
}
