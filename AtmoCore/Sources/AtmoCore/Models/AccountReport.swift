import Foundation
import ATProtoKit

// MARK: - AccountReport
// The report taxonomy the official Bluesky app uses (its ReportDialog):
// a top-level category, then a specific reason inside it, mapped to the
// Ozone reason types (`tools.ozone.report.defs#reason*`). The flow is
// category → reason → moderation service → submit; "Other" reasons ask
// for free-text details, and a few reasons may only go to Bluesky's own
// moderation service.
public enum AccountReport {

    /// Bluesky's moderation service (the labeler every account is
    /// subscribed to by default). Reports go here unless the user picks
    /// another subscribed labeler.
    public static let blueskyModerationDID = "did:plc:ar7c4by46qjdydhdevvrndac"

    /// Copyright / legal requests are handled out-of-band, via a web form.
    public static let copyrightSupportURL = URL(string: "https://bsky.social/about/support/copyright")!

    /// Lexicon limit for the free-text `reason` field (graphemes).
    public static let detailsMaxLength = 2000

    // MARK: Option

    public struct Option: Identifiable, Hashable, Sendable {
        public let title: String
        public let reason: ComAtprotoLexicon.Moderation.ReasonTypeDefinition

        public var id: String { reason.rawValue }

        /// "Other …" reasons: the app prompts for additional details.
        public var asksForDetails: Bool { Self.detailReasons.contains(reason) }

        /// Reasons that should only be sent to Bluesky's moderation service.
        public var isBlueskyOnly: Bool { Self.blueskyOnlyReasons.contains(reason) }

        public init(_ title: String, _ reason: ComAtprotoLexicon.Moderation.ReasonTypeDefinition) {
            self.title = title
            self.reason = reason
        }

        static let detailReasons: Set<ComAtprotoLexicon.Moderation.ReasonTypeDefinition> = [
            .reasonViolenceOther, .reasonSexualOther, .reasonChildSafetyOther,
            .reasonHarassmentOther, .reasonMisleadingOther, .reasonRuleOther,
            .reasonSelfHarmOther, .reasonOther
        ]

        static let blueskyOnlyReasons: Set<ComAtprotoLexicon.Moderation.ReasonTypeDefinition> = [
            .reasonChildSafetyCSAM, .reasonChildSafetyGroom, .reasonChildSafetyOther,
            .reasonViolenceExtremistContent
        ]
    }

    // MARK: Category

    public struct Category: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let description: String
        public let options: [Option]
    }

    /// Same order and copy as the official app.
    public static let categories: [Category] = [
        Category(
            id: "misleading",
            title: "Misleading",
            description: "Spam or other inauthentic behavior or deception",
            options: [
                Option("Spam", .reasonMisleadingSpam),
                Option("Scam", .reasonMisleadingScam),
                Option("Fake account or bot", .reasonMisleadingBot),
                Option("Impersonation", .reasonMisleadingImpersonation),
                Option("False information about elections", .reasonMisleadingElections),
                Option("Other misleading content", .reasonMisleadingOther)
            ]
        ),
        Category(
            id: "sexualAdultContent",
            title: "Adult content",
            description: "Unlabeled, abusive, or non-consensual adult content",
            options: [
                Option("Unlabeled adult content", .reasonSexualUnlabeled),
                Option("Adult sexual abuse content", .reasonSexualAbuseContent),
                Option("Non-consensual intimate imagery", .reasonSexualNCII),
                Option("Deepfake adult content", .reasonSexualDeepfake),
                Option("Animal sexual abuse", .reasonSexualAnimal),
                Option("Other sexual violence content", .reasonSexualOther)
            ]
        ),
        Category(
            id: "harassmentHate",
            title: "Harassment or hate",
            description: "Abusive or discriminatory behavior",
            options: [
                Option("Trolling", .reasonHarassmentTroll),
                Option("Targeted harassment", .reasonHarassmentTargeted),
                Option("Hate speech", .reasonHarassmentHateSpeech),
                Option("Doxxing", .reasonHarassmentDoxxing),
                Option("Other harassing or hateful content", .reasonHarassmentOther)
            ]
        ),
        Category(
            id: "violencePhysicalHarm",
            title: "Violence",
            description: "Violent or threatening content",
            options: [
                Option("Animal welfare", .reasonViolenceAnimal),
                Option("Threats or incitement", .reasonViolenceThreats),
                Option("Graphic violent content", .reasonViolenceGraphicContent),
                Option("Glorification of violence", .reasonViolenceGlorification),
                Option("Extremist content", .reasonViolenceExtremistContent),
                Option("Human trafficking", .reasonViolenceTrafficking),
                Option("Other violent content", .reasonViolenceOther)
            ]
        ),
        Category(
            id: "childSafety",
            title: "Child safety",
            description: "Harming or endangering minors",
            options: [
                Option("Child Sexual Abuse Material (CSAM)", .reasonChildSafetyCSAM),
                Option("Grooming or predatory behavior", .reasonChildSafetyGroom),
                Option("Privacy violation of a minor", .reasonChildSafetyPrivacy),
                Option("Minor harassment or bullying", .reasonChildSafetyHarassment),
                Option("Other child safety issue", .reasonChildSafetyOther)
            ]
        ),
        Category(
            id: "selfHarm",
            title: "Self-harm or dangerous behaviors",
            description: "Harmful or high-risk activities",
            options: [
                Option("Content promoting or depicting self-harm", .reasonSelfHarmContent),
                Option("Eating disorders", .reasonSelfHarmED),
                Option("Dangerous challenges or activities", .reasonSelfHarmStunts),
                Option("Dangerous substances or drug abuse", .reasonSelfHarmSubstances),
                Option("Other dangerous content", .reasonSelfHarmOther)
            ]
        ),
        Category(
            id: "ruleBreaking",
            title: "Breaking site rules",
            description: "Banned activities or security violations",
            options: [
                Option("Hacking or system attacks", .reasonRuleSiteSecurity),
                Option("Promoting or selling prohibited items or services", .reasonRuleProhibitedSales),
                Option("Banned user returning", .reasonRuleBanEvasion),
                Option("Other network rule-breaking", .reasonRuleOther)
            ]
        ),
        Category(
            id: "other",
            title: "Other",
            description: "An issue not included in these options",
            options: [
                Option("Other", .reasonOther)
            ]
        )
    ]
}

// MARK: - ModerationServiceInfo
/// A labeler the user can send a report to — Bluesky's own service plus
/// any labelers the account subscribes to.
public struct ModerationServiceInfo: Identifiable, Hashable, Sendable {
    public let did: String
    public let handle: String
    public let displayName: String?
    public let avatarURL: URL?

    public var id: String { did }
    public var isBluesky: Bool { did == AccountReport.blueskyModerationDID }
    public var name: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return "@\(handle)"
    }

    public init(did: String, handle: String, displayName: String?, avatarURL: URL?) {
        self.did = did
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
    }

    /// Offline fallback so the picker always has Bluesky's service even
    /// when the profile lookup fails.
    public static let bluesky = ModerationServiceInfo(
        did: AccountReport.blueskyModerationDID,
        handle: "moderation.bsky.app",
        displayName: "Bluesky Moderation Service",
        avatarURL: nil
    )
}
