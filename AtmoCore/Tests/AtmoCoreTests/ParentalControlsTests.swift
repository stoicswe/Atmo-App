import Foundation
import Testing
@testable import AtmoCore

/// Covers the family-controls model: age mapping, child defaults, the
/// parent-only mutation surface, and persistence.
@MainActor
struct ParentalControlsTests {

    private func freshStore(_ name: String = UUID().uuidString) -> (ParentalControlsStore, UserDefaults) {
        let suite = UserDefaults(suiteName: "test.\(name)")!
        suite.removePersistentDomain(forName: "test.\(name)")
        return (ParentalControlsStore(defaults: suite), suite)
    }

    // MARK: Age mapping

    @Test func ageRangeMapping() {
        #expect(AgeCategory.from(lowerBound: nil, upperBound: 12) == .child)
        #expect(AgeCategory.from(lowerBound: 13, upperBound: 15) == .teen)
        #expect(AgeCategory.from(lowerBound: 16, upperBound: 17) == .teen)
        #expect(AgeCategory.from(lowerBound: 18, upperBound: nil) == .adult)
        #expect(AgeCategory.from(lowerBound: nil, upperBound: nil) == .unknown)
    }

    // MARK: Defaults & activation

    @Test func unknownAccountsRunUnrestricted() {
        let (store, _) = freshStore()
        #expect(!store.isChildAccount)
        #expect(store.active == .unrestricted)
    }

    @Test func becomingAChildAppliesManagedDefaultsAndGates() {
        let (store, _) = freshStore()
        store.setAgeCategory(.child)
        #expect(store.isChildAccount)
        #expect(store.isManagedMinor)
        #expect(store.active == .managedDefaults)
    }

    @Test func teensAreManagedButNotGated() {
        let (store, _) = freshStore()
        store.setAgeCategory(.teen)
        #expect(!store.isChildAccount)
        #expect(store.isManagedMinor)
        #expect(store.active == .managedDefaults)
        #expect(store.active.requiresAskToDM)
        #expect(!store.active.showsPostsInDiscover)
        #expect(!store.active.allowsDMNotifications)
        #expect(store.active.locksSensitiveMediaHidden)
        #expect(!store.active.allowsLinkBrowsing)
        #expect(!store.active.allowsExploreSuggestions)
    }

    @Test func adultsGetExploreSuggestions() {
        let (store, _) = freshStore()
        #expect(store.active.allowsExploreSuggestions)
    }

    @Test func childToTeenKeepsParentDecisions() {
        // Moving within the managed brackets must not wipe what a parent
        // already granted.
        let (store, _) = freshStore()
        store.setAgeCategory(.child)
        store.applyParentDecision { $0.allowsLinkBrowsing = true }
        store.setAgeCategory(.teen)
        #expect(store.active.allowsLinkBrowsing)
    }

    @Test func adultsIgnoreStoredControls() {
        let (store, _) = freshStore()
        store.setAgeCategory(.child)
        store.setAgeCategory(.adult)
        #expect(store.active == .unrestricted)
    }

    // MARK: Parent decisions

    @Test func parentDecisionsOnlyApplyToChildren() {
        let (store, _) = freshStore()
        store.applyParentDecision { $0.allowsLinkBrowsing = true }
        #expect(store.active == .unrestricted)

        store.setAgeCategory(.teen)
        store.applyParentDecision { $0.allowsLinkBrowsing = true }
        #expect(store.active.allowsLinkBrowsing)
        // The rest stay managed.
        #expect(store.active.requiresAskToDM)
    }

    // MARK: Sensitive media lock

    @Test func minorLockForcesHideRegardlessOfStoredPolicy() {
        let (store, _) = freshStore()
        store.setAgeCategory(.teen)
        #expect(store.effectiveSensitiveMediaPolicy(stored: .show) == .hide)
        #expect(store.effectiveSensitiveMediaPolicy(stored: .blur) == .hide)
    }

    @Test func adultsKeepTheirStoredPolicy() {
        let (store, _) = freshStore()
        #expect(store.effectiveSensitiveMediaPolicy(stored: .show) == .show)
    }

    // MARK: Ask-to-DM

    @Test func askToDMGatesUntilApproved() {
        let (store, _) = freshStore()
        store.setAgeCategory(.teen)
        #expect(!store.canStartDM(with: "friend.bsky.social"))
        store.recordParentDMDecision(handle: "Friend.bsky.social", approved: true)
        #expect(store.canStartDM(with: "friend.bsky.social"))
        store.recordParentDMDecision(handle: "friend.bsky.social", approved: false)
        #expect(!store.canStartDM(with: "friend.bsky.social"))
    }

    @Test func unmanagedAccountsNeverGate() {
        let (store, _) = freshStore()
        #expect(store.canStartDM(with: "anyone.bsky.social"))
    }

    // MARK: Persistence

    @Test func stateSurvivesRelaunch() {
        let name = UUID().uuidString
        let (store, suite) = freshStore(name)
        store.setAgeCategory(.child)
        store.applyParentDecision { $0.allowsDMNotifications = true }

        let reloaded = ParentalControlsStore(defaults: suite)
        #expect(reloaded.isChildAccount)
        #expect(reloaded.active.allowsDMNotifications)
        #expect(reloaded.active.requiresAskToDM)
    }
}
