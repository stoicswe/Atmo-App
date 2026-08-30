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
            syncedKeyValue: UbiquitousKeyValueStore(),
            postIndexer: postIndexer,
            // ATProtoKit's own Keychain-backed store. The default service
            // name ("ATProtoKit") is deliberately preserved so refresh
            // tokens stored by ATProtoKit 0.32.x remain readable after the
            // 0.34 credential-storage migration.
            makeCredentialStore: { AppleSecureKeychain() },
            foregroundNotification: foregroundNotification,
            timelineRefreshInterval: timelineRefreshInterval
        )
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
