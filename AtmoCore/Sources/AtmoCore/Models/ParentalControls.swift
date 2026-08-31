import Foundation
import Observation

// MARK: - Age Category
/// The account holder's age bracket, from Apple's Declared Age Range (a
/// parent shares it for child accounts) or unknown when nothing was shared.
public enum AgeCategory: String, Sendable, CaseIterable {
    case unknown
    case child   // under 13
    case teen    // 13–17
    case adult   // 18+

    /// Maps a declared age range (as lower/upper bounds) to a category.
    public static func from(lowerBound: Int?, upperBound: Int?) -> AgeCategory {
        if let upper = upperBound {
            if upper < 13 { return .child }
            if upper < 18 { return .teen }
        }
        if let lower = lowerBound {
            if lower >= 18 { return .adult }
            if lower >= 13 { return .teen }
        }
        return .unknown
    }
}

// MARK: - Parental Control Set
/// The five family controls. For a child account each starts at a managed
/// default; changes flow only through `ParentalControlsStore.applyParentDecision`
/// (the surface a parent-approval flow calls) — never child-editable UI.
public struct ParentalControlSet: Equatable, Sendable, Codable {
    /// Starting a NEW conversation requires asking a parent first.
    public var requiresAskToDM: Bool
    /// Whether the account's posts may appear in Bluesky's Discover feed.
    public var showsPostsInDiscover: Bool
    /// Whether incoming-message notifications are surfaced to the child.
    public var allowsDMNotifications: Bool
    /// Sensitive media is forced to Hide, and the setting is locked.
    public var locksSensitiveMediaHidden: Bool
    /// Whether tapped links may open in the in-app browser.
    public var allowsLinkBrowsing: Bool

    public init(
        requiresAskToDM: Bool,
        showsPostsInDiscover: Bool,
        allowsDMNotifications: Bool,
        locksSensitiveMediaHidden: Bool,
        allowsLinkBrowsing: Bool
    ) {
        self.requiresAskToDM = requiresAskToDM
        self.showsPostsInDiscover = showsPostsInDiscover
        self.allowsDMNotifications = allowsDMNotifications
        self.locksSensitiveMediaHidden = locksSensitiveMediaHidden
        self.allowsLinkBrowsing = allowsLinkBrowsing
    }

    /// What a child account starts with (Discover off is Bluesky's own
    /// child default).
    public static let childDefaults = ParentalControlSet(
        requiresAskToDM: true,
        showsPostsInDiscover: false,
        allowsDMNotifications: false,
        locksSensitiveMediaHidden: true,
        allowsLinkBrowsing: false
    )

    /// Everything open — what non-managed accounts effectively run under.
    public static let unrestricted = ParentalControlSet(
        requiresAskToDM: false,
        showsPostsInDiscover: true,
        allowsDMNotifications: true,
        locksSensitiveMediaHidden: false,
        allowsLinkBrowsing: true
    )
}

// MARK: - Store
/// App-wide parental-controls state: the declared age category plus the
/// managed control set, persisted across launches.
@Observable
@MainActor
public final class ParentalControlsStore {

    public static let shared = ParentalControlsStore()

    public private(set) var ageCategory: AgeCategory
    public private(set) var controls: ParentalControlSet
    /// Handles (lowercased) a parent has approved for direct messages,
    /// via the ask-a-parent flow.
    public private(set) var approvedDMHandles: Set<String>

    private let defaults: UserDefaults
    private static let ageKey = "atmo.parental.ageCategory"
    private static let controlsKey = "atmo.parental.controls"
    private static let approvedDMsKey = "atmo.parental.approvedDMs"

    /// Internal so tests can run against an isolated UserDefaults suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedAge = defaults.string(forKey: Self.ageKey)
            .flatMap(AgeCategory.init(rawValue:)) ?? .unknown
        self.ageCategory = storedAge
        if let data = defaults.data(forKey: Self.controlsKey),
           let decoded = try? JSONDecoder().decode(ParentalControlSet.self, from: data) {
            self.controls = decoded
        } else {
            self.controls = storedAge == .child ? .childDefaults : .unrestricted
        }
        self.approvedDMHandles = Set(defaults.stringArray(forKey: Self.approvedDMsKey) ?? [])
    }

    public var isChildAccount: Bool { ageCategory == .child }

    /// The controls actually in force: managed for a child, open otherwise.
    public var active: ParentalControlSet {
        isChildAccount ? controls : .unrestricted
    }

    /// Records the declared age category. Becoming a child account resets
    /// the controls to the managed defaults.
    public func setAgeCategory(_ category: AgeCategory) {
        let becameChild = category == .child && ageCategory != .child
        ageCategory = category
        if becameChild {
            controls = .childDefaults
        }
        persist()
    }

    /// The only mutation surface for the managed controls — reserved for
    /// parent-approval flows. No-op for non-child accounts.
    public func applyParentDecision(_ mutate: (inout ParentalControlSet) -> Void) {
        guard isChildAccount else { return }
        mutate(&controls)
        persist()
    }

    /// The sensitive-media policy actually in force, given the stored
    /// user preference.
    public func effectiveSensitiveMediaPolicy(stored: SensitiveMediaPolicy) -> SensitiveMediaPolicy {
        active.locksSensitiveMediaHidden ? .hide : stored
    }

    // MARK: Ask-to-DM

    /// Whether a new conversation with `handle` may start right away —
    /// true unless ask-to-DM is in force and no parent approval exists.
    public func canStartDM(with handle: String) -> Bool {
        guard active.requiresAskToDM else { return true }
        return approvedDMHandles.contains(handle.lowercased())
    }

    /// Records a parent's answer to an ask-to-message request.
    public func recordParentDMDecision(handle: String, approved: Bool) {
        guard isChildAccount else { return }
        if approved {
            approvedDMHandles.insert(handle.lowercased())
        } else {
            approvedDMHandles.remove(handle.lowercased())
        }
        persist()
    }

    private func persist() {
        defaults.set(ageCategory.rawValue, forKey: Self.ageKey)
        if let data = try? JSONEncoder().encode(controls) {
            defaults.set(data, forKey: Self.controlsKey)
        }
        defaults.set(Array(approvedDMHandles).sorted(), forKey: Self.approvedDMsKey)
    }
}
