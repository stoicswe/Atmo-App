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
    /// Every mature-content category (profanity, sexuality, violence, …)
    /// is forced to Hide, and those settings are locked.
    public var hidesMatureContent: Bool
    /// Whether the Search page may show Bluesky's algorithmic Explore
    /// suggestions (trending topics, discover feeds, suggested accounts).
    public var allowsExploreSuggestions: Bool

    public init(
        requiresAskToDM: Bool,
        showsPostsInDiscover: Bool,
        allowsDMNotifications: Bool,
        locksSensitiveMediaHidden: Bool,
        allowsLinkBrowsing: Bool,
        hidesMatureContent: Bool = false,
        allowsExploreSuggestions: Bool = true
    ) {
        self.requiresAskToDM = requiresAskToDM
        self.showsPostsInDiscover = showsPostsInDiscover
        self.allowsDMNotifications = allowsDMNotifications
        self.locksSensitiveMediaHidden = locksSensitiveMediaHidden
        self.allowsLinkBrowsing = allowsLinkBrowsing
        self.hidesMatureContent = hidesMatureContent
        self.allowsExploreSuggestions = allowsExploreSuggestions
    }

    /// Backward-compatible decoding: control sets persisted before
    /// `hidesMatureContent` existed decode with the field defaulted from
    /// the sensitive-media lock (a managed minor stays fully covered).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requiresAskToDM = try container.decode(Bool.self, forKey: .requiresAskToDM)
        showsPostsInDiscover = try container.decode(Bool.self, forKey: .showsPostsInDiscover)
        allowsDMNotifications = try container.decode(Bool.self, forKey: .allowsDMNotifications)
        locksSensitiveMediaHidden = try container.decode(Bool.self, forKey: .locksSensitiveMediaHidden)
        allowsLinkBrowsing = try container.decode(Bool.self, forKey: .allowsLinkBrowsing)
        hidesMatureContent = try container.decodeIfPresent(Bool.self, forKey: .hidesMatureContent)
            ?? locksSensitiveMediaHidden
        // Managed sets persisted before this control existed default OFF.
        allowsExploreSuggestions = try container.decodeIfPresent(Bool.self, forKey: .allowsExploreSuggestions)
            ?? false
    }

    /// What a family-managed minor account starts with (Discover off is
    /// Bluesky's own default for young accounts).
    public static let managedDefaults = ParentalControlSet(
        requiresAskToDM: true,
        showsPostsInDiscover: false,
        allowsDMNotifications: false,
        locksSensitiveMediaHidden: true,
        allowsLinkBrowsing: false,
        hidesMatureContent: true,
        allowsExploreSuggestions: false
    )

    /// Everything open — what non-managed accounts effectively run under.
    public static let unrestricted = ParentalControlSet(
        requiresAskToDM: false,
        showsPostsInDiscover: true,
        allowsDMNotifications: true,
        locksSensitiveMediaHidden: false,
        allowsLinkBrowsing: true,
        hidesMatureContent: false,
        allowsExploreSuggestions: true
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
            self.controls = (storedAge == .child || storedAge == .teen)
                ? .managedDefaults
                : .unrestricted
        }
        self.approvedDMHandles = Set(defaults.stringArray(forKey: Self.approvedDMsKey) ?? [])
    }

    /// Under 13: the app's social surfaces are disabled entirely (the
    /// App Store "Social Media Disabled for Users Under 13" posture) —
    /// UIs show the child gate instead of the app.
    public var isChildAccount: Bool { ageCategory == .child }

    /// A family-managed minor (child or teen). Teens get the app with the
    /// managed controls in force; children are gated before this matters.
    public var isManagedMinor: Bool {
        ageCategory == .child || ageCategory == .teen
    }

    /// The controls actually in force: managed for a minor, open otherwise.
    public var active: ParentalControlSet {
        isManagedMinor ? controls : .unrestricted
    }

    /// Records the declared age category. Entering a managed bracket
    /// (child or teen) from an unmanaged one resets the controls to the
    /// managed defaults.
    public func setAgeCategory(_ category: AgeCategory) {
        let wasManaged = isManagedMinor
        ageCategory = category
        if isManagedMinor && !wasManaged {
            controls = .managedDefaults
        }
        persist()
    }

    /// The only mutation surface for the managed controls — reserved for
    /// parent-approval flows. No-op for unmanaged accounts.
    public func applyParentDecision(_ mutate: (inout ParentalControlSet) -> Void) {
        guard isManagedMinor else { return }
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
        guard isManagedMinor else { return }
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
