import Foundation
import Testing
@testable import AtmoCore

/// Covers the Age Ratings content controls: category detection from text
/// and labels, the strictest-policy resolution, and the parental lock.
struct MatureContentTests {

    // MARK: Detection

    @Test func detectsTextCategoriesOnWordBoundaries() {
        let matched = MatureContentScreener.categories(
            text: "This whiskey-fueled HORROR marathon was violent as fuck"
        )
        #expect(matched.contains(.substances))
        #expect(matched.contains(.horror))
        #expect(matched.contains(.violence))
        #expect(matched.contains(.profanity))
        #expect(!matched.contains(.weapons))
    }

    @Test func substringsNeverTrip() {
        // "class", "assassin", "mishit" contain listed words as substrings.
        let matched = MatureContentScreener.categories(text: "The class assassin mishit the target")
        #expect(matched.isEmpty)
    }

    @Test func labelsEstablishSexualityCategories() {
        #expect(MatureContentScreener.categories(text: "", labels: ["porn"]).contains(.graphicSexual))
        #expect(MatureContentScreener.categories(text: "", labels: ["sexual"]).contains(.sexualNudity))
        #expect(MatureContentScreener.categories(text: "", labels: ["nudity"]).contains(.sexualNudity))
        let gore = MatureContentScreener.categories(text: "", labels: ["graphic-media"])
        #expect(gore.contains(.graphicViolence))
        #expect(gore.contains(.horror))
    }

    @Test func cleanTextMatchesNothing() {
        #expect(MatureContentScreener.categories(text: "Lovely sunset over the harbor tonight").isEmpty)
    }

    // MARK: Policy resolution

    @Test func unsetCategoriesDefaultToBlur() {
        let suite = UserDefaults(suiteName: "test.mature.\(UUID().uuidString)")!
        for category in MatureContentCategory.allCases {
            #expect(MatureContentPreferences.storedPolicy(for: category, defaults: suite) == .blur)
        }
        #expect(ContentControlsMode.stored(defaults: suite) == .blur)
    }

    @MainActor
    @Test func uniformMasterModeOverridesPerCategorySettings() {
        let suite = UserDefaults(suiteName: "test.mature.\(UUID().uuidString)")!
        let store = ParentalControlsStore(defaults: suite)
        // Per-category says hide, but the uniform master says show.
        suite.set(SensitiveMediaPolicy.hide.rawValue, forKey: MatureContentCategory.profanity.storageKey)
        suite.set(ContentControlsMode.show.rawValue, forKey: ContentControlsMode.storageKey)
        #expect(store.matureTreatment(text: "well shit", labels: [], defaults: suite).policy == .show)

        // Switching to Custom re-activates the per-category setting.
        suite.set(ContentControlsMode.custom.rawValue, forKey: ContentControlsMode.storageKey)
        #expect(store.matureTreatment(text: "well shit", labels: [], defaults: suite).policy == .hide)
    }

    @Test func mediaPolicyFollowsMasterModeExceptCustom() {
        let suite = UserDefaults(suiteName: "test.mature.\(UUID().uuidString)")!
        suite.set(SensitiveMediaPolicy.show.rawValue, forKey: SensitiveMediaPolicy.storageKey)
        suite.set(ContentControlsMode.hide.rawValue, forKey: ContentControlsMode.storageKey)
        #expect(SensitiveMediaPolicy.currentEffectiveStored(defaults: suite) == .hide)

        suite.set(ContentControlsMode.custom.rawValue, forKey: ContentControlsMode.storageKey)
        #expect(SensitiveMediaPolicy.currentEffectiveStored(defaults: suite) == .show)
    }

    @MainActor
    @Test func strictestPolicyWinsAcrossCategories() {
        let suite = UserDefaults(suiteName: "test.mature.\(UUID().uuidString)")!
        let store = ParentalControlsStore(defaults: suite)
        // Per-category settings only apply in Custom mode.
        suite.set(ContentControlsMode.custom.rawValue, forKey: ContentControlsMode.storageKey)
        suite.set(SensitiveMediaPolicy.blur.rawValue, forKey: MatureContentCategory.profanity.storageKey)
        suite.set(SensitiveMediaPolicy.hide.rawValue, forKey: MatureContentCategory.violence.storageKey)

        let blurred = store.matureTreatment(text: "well shit", labels: [], defaults: suite)
        #expect(blurred.policy == .blur)
        #expect(blurred.category == .profanity)

        let hidden = store.matureTreatment(text: "shit, that murder scene", labels: [], defaults: suite)
        #expect(hidden.policy == .hide)

        let clean = store.matureTreatment(text: "sunny day", labels: [], defaults: suite)
        #expect(clean.policy == .show)
        #expect(clean.category == nil)
    }

    @MainActor
    @Test func managedMinorsAreLockedToHide() {
        let suite = UserDefaults(suiteName: "test.mature.\(UUID().uuidString)")!
        let store = ParentalControlsStore(defaults: suite)
        store.setAgeCategory(.teen)
        // Even with an explicit Show stored, the lock forces Hide.
        suite.set(SensitiveMediaPolicy.show.rawValue, forKey: MatureContentCategory.profanity.storageKey)
        let treatment = store.matureTreatment(text: "well shit", labels: [], defaults: suite)
        #expect(treatment.policy == .hide)
    }

    // MARK: Persistence compatibility

    @Test func oldControlSetsDecodeWithMatureDefaultFromSensitiveLock() throws {
        let legacyManaged = Data("""
        {"requiresAskToDM":true,"showsPostsInDiscover":false,"allowsDMNotifications":false,"locksSensitiveMediaHidden":true,"allowsLinkBrowsing":false}
        """.utf8)
        let decoded = try JSONDecoder().decode(ParentalControlSet.self, from: legacyManaged)
        #expect(decoded.hidesMatureContent)

        let legacyOpen = Data("""
        {"requiresAskToDM":false,"showsPostsInDiscover":true,"allowsDMNotifications":true,"locksSensitiveMediaHidden":false,"allowsLinkBrowsing":true}
        """.utf8)
        #expect(!(try JSONDecoder().decode(ParentalControlSet.self, from: legacyOpen)).hidesMatureContent)
    }
}
