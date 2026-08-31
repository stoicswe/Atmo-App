import Foundation

// MARK: - Mature Content Categories
/// The App Store Age Ratings content categories (Step 2 "Mature Themes",
/// Step 4 "Sexuality or Nudity", Step 5 "Violence"), as in-app content
/// controls: each category carries its own Show/Blur/Hide policy —
/// adult-configurable, locked to Hide for family-managed minors.
/// Cartoon and realistic violence share one control (text heuristics
/// can't tell them apart, and one switch covers both questionnaire rows).
public enum MatureContentCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    // Step 2 — Mature Themes
    case profanity
    case horror
    case substances
    // Step 4 — Sexuality or Nudity
    case suggestive
    case sexualNudity
    case graphicSexual
    // Step 5 — Violence
    case violence
    case graphicViolence
    case weapons

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .profanity:     return "Profanity & Crude Humor"
        case .horror:        return "Horror & Fear"
        case .substances:    return "Alcohol, Tobacco & Drugs"
        case .suggestive:    return "Suggestive Themes"
        case .sexualNudity:  return "Sexual Content & Nudity"
        case .graphicSexual: return "Graphic Sexual Content"
        case .violence:        return "Violence"
        case .graphicViolence: return "Graphic Violence"
        case .weapons:         return "Guns & Weapons"
        }
    }

    public var iconName: String {
        switch self {
        case .profanity:     return "exclamationmark.bubble"
        case .horror:        return "theatermasks"
        case .substances:    return "wineglass"
        case .suggestive:    return "flame"
        case .sexualNudity:  return "exclamationmark.shield"
        case .graphicSexual: return "nosign"
        case .violence:        return "burst"
        case .graphicViolence: return "drop.triangle"
        case .weapons:         return "scope"
        }
    }

    /// Per-category policy storage key (holds a `SensitiveMediaPolicy`
    /// raw value; unset categories default to Blur).
    public var storageKey: String { "atmo.mature.\(rawValue)" }
}

// MARK: - Screener
/// On-device detection of mature themes, from two signals:
///  • Bluesky moderation labels (authoritative for sexuality/nudity —
///    "porn", "sexual", "nudity" — and gore).
///  • A conservative word-boundary text match against small per-category
///    lists, for the themes labelers don't cover.
/// Best-effort by design: it powers an opt-in comfort filter, not a
/// moderation claim.
public enum MatureContentScreener {

    static let wordlists: [MatureContentCategory: Set<String>] = [
        .profanity: [
            "fuck", "fucking", "fucked", "shit", "bullshit", "bitch",
            "asshole", "cunt", "motherfucker", "dickhead", "goddamn",
        ],
        .horror: [
            "horror", "gore", "gory", "jumpscare", "slasher", "haunted",
            "haunting", "paranormal", "creepypasta", "nightmarish",
        ],
        .substances: [
            "alcohol", "vodka", "whiskey", "tequila", "drunk", "hangover",
            "tobacco", "nicotine", "vape", "vaping", "weed", "marijuana",
            "cannabis", "cocaine", "heroin", "meth", "fentanyl",
        ],
        .suggestive: [
            "nsfw", "lewd", "horny", "kink", "fetish", "thirst",
        ],
        .sexualNudity: [
            "nude", "nudes", "naked", "topless",
        ],
        .graphicSexual: [
            "porn", "hentai", "xxx",
        ],
        .violence: [
            "violence", "violent", "assault", "murder", "murdered",
            "killing", "stabbing", "beating", "massacre", "brawl",
        ],
        .graphicViolence: [
            "torture", "beheading", "execution", "mutilation",
            "dismembered", "bloodbath",
        ],
        .weapons: [
            "gun", "guns", "firearm", "firearms", "rifle", "pistol",
            "shotgun", "ammunition", "ammo", "grenade", "shooting",
        ],
    ]

    /// Bluesky label values → the categories they establish.
    static let labelMap: [String: [MatureContentCategory]] = [
        "porn": [.graphicSexual],
        "sexual": [.sexualNudity],
        "nudity": [.sexualNudity],
        "sexual-figurative": [.suggestive],
        "graphic-media": [.graphicViolence, .horror],
        "gore": [.graphicViolence, .horror],
    ]

    /// Which mature categories a post touches, from its text and labels.
    /// Text matching is case-insensitive, whole-word only ("class" never
    /// trips on "ass").
    public static func categories(text: String, labels: [String] = []) -> Set<MatureContentCategory> {
        var matched: Set<MatureContentCategory> = []
        for label in labels {
            for category in labelMap[label] ?? [] { matched.insert(category) }
        }
        if !text.isEmpty {
            let words = Set(
                text.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
            )
            for (category, list) in wordlists where !words.isDisjoint(with: list) {
                matched.insert(category)
            }
        }
        return matched
    }
}

// MARK: - Master mode
/// The top-level content-controls switch: one uniform Show/Blur/Hide
/// treatment for everything, or Custom to configure each category
/// individually. Defaults to Blur.
public enum ContentControlsMode: String, CaseIterable, Identifiable, Sendable {
    case show
    case blur
    case hide
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .show:   return "Show"
        case .blur:   return "Blur"
        case .hide:   return "Hide"
        case .custom: return "Custom"
        }
    }

    /// The uniform policy this mode imposes on every category — nil for
    /// Custom (per-category settings take over).
    public var uniformPolicy: SensitiveMediaPolicy? {
        switch self {
        case .show:   return .show
        case .blur:   return .blur
        case .hide:   return .hide
        case .custom: return nil
        }
    }

    public static let storageKey = "atmo.content.mode"

    public static func stored(defaults: UserDefaults = .standard) -> ContentControlsMode {
        defaults.string(forKey: storageKey)
            .flatMap(ContentControlsMode.init(rawValue:)) ?? .blur
    }
}

extension SensitiveMediaPolicy {
    /// The stored media policy with the master mode applied: a uniform
    /// mode wins; Custom falls back to the media-specific stored value.
    public static func currentEffectiveStored(defaults: UserDefaults = .standard) -> SensitiveMediaPolicy {
        ContentControlsMode.stored(defaults: defaults).uniformPolicy
            ?? stored(rawValue: defaults.string(forKey: storageKey))
    }
}

// MARK: - Stored preferences
public enum MatureContentPreferences {
    /// The user's stored policy for a category. Unset categories default
    /// to Blur — covered until the user says otherwise, matching the
    /// sensitive-media default.
    public static func storedPolicy(
        for category: MatureContentCategory,
        defaults: UserDefaults = .standard
    ) -> SensitiveMediaPolicy {
        guard let raw = defaults.string(forKey: category.storageKey),
              let policy = SensitiveMediaPolicy(rawValue: raw)
        else { return .blur }
        return policy
    }
}

extension ParentalControlsStore {
    /// The policy actually in force for a mature category: family-managed
    /// minors are locked to Hide; everyone else keeps their stored choice.
    public func effectiveMaturePolicy(stored: SensitiveMediaPolicy) -> SensitiveMediaPolicy {
        active.hidesMatureContent ? .hide : stored
    }

    /// The strictest treatment across every category a post touches, with
    /// the parental lock applied. `.show` when nothing matches.
    public func matureTreatment(
        text: String,
        labels: [String],
        defaults: UserDefaults = .standard
    ) -> (policy: SensitiveMediaPolicy, category: MatureContentCategory?) {
        matureTreatment(
            categories: MatureContentScreener.categories(text: text, labels: labels),
            defaults: defaults
        )
    }

    /// Same resolution over pre-computed categories (UIs cache detection
    /// per post URI and re-resolve policies cheaply on render).
    public func matureTreatment(
        categories matched: Set<MatureContentCategory>,
        defaults: UserDefaults = .standard
    ) -> (policy: SensitiveMediaPolicy, category: MatureContentCategory?) {
        var strictest: (SensitiveMediaPolicy, MatureContentCategory?) = (.show, nil)
        // Master mode: a uniform Show/Blur/Hide overrides every category;
        // Custom defers to the per-category settings.
        let uniform = ContentControlsMode.stored(defaults: defaults).uniformPolicy
        for category in MatureContentCategory.allCases where matched.contains(category) {
            let policy = effectiveMaturePolicy(
                stored: uniform ?? MatureContentPreferences.storedPolicy(for: category, defaults: defaults)
            )
            switch (strictest.0, policy) {
            case (_, .hide):
                return (.hide, category)
            case (.show, .blur):
                strictest = (.blur, category)
            default:
                break
            }
        }
        return strictest
    }
}
