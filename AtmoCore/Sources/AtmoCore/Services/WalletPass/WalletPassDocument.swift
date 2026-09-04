import Foundation

// MARK: - WalletPassDocument
/// The `pass.json` of a Wallet profile pass — a QR code that opens the
/// account's Bluesky profile, with the handle, join date, and DID printed
/// on the card. Both the classic `generic` layout and the iOS 27 poster
/// layout (`posterGeneric`) are described so one file renders anywhere;
/// Wallet picks the poster when it can.
///
/// Encoding is deterministic (sorted keys) so the same account and theme
/// always produce the same bytes — useful for tests and for spotting
/// unchanged passes.
public struct WalletPassDocument: Encodable, Sendable, Equatable {

    public struct Field: Encodable, Sendable, Equatable {
        public var key: String
        public var label: String?
        public var value: String
        /// `PKDateStyleShort` etc. — tells Wallet to format `value`
        /// (an ISO 8601 timestamp) as a localised date.
        public var dateStyle: String?
        /// `PKTextAlignmentNatural` / `Left` / `Center` / `Right`.
        public var textAlignment: String?

        public init(key: String, label: String? = nil, value: String, dateStyle: String? = nil, textAlignment: String? = nil) {
            self.key = key
            self.label = label
            self.value = value
            self.dateStyle = dateStyle
            self.textAlignment = textAlignment
        }
    }

    public struct FieldSet: Encodable, Sendable, Equatable {
        public var headerFields: [Field] = []
        public var primaryFields: [Field] = []
        public var secondaryFields: [Field] = []
        public var auxiliaryFields: [Field] = []
        /// Poster layouts only; omitted from the classic layout.
        public var footerFields: [Field]? = nil
        public var backFields: [Field] = []

        public init(headerFields: [Field] = [], primaryFields: [Field] = [], secondaryFields: [Field] = [], auxiliaryFields: [Field] = [], footerFields: [Field]? = nil, backFields: [Field] = []) {
            self.headerFields = headerFields
            self.primaryFields = primaryFields
            self.secondaryFields = secondaryFields
            self.auxiliaryFields = auxiliaryFields
            self.footerFields = footerFields
            self.backFields = backFields
        }
    }

    public struct Barcode: Encodable, Sendable, Equatable {
        public var format: String
        public var message: String
        public var messageEncoding: String
        /// Printed under the code — the handle, so a person can read it
        /// when the code won't scan.
        public var altText: String?

        public init(format: String = "PKBarcodeFormatQR", message: String, messageEncoding: String = "iso-8859-1", altText: String? = nil) {
            self.format = format
            self.message = message
            self.messageEncoding = messageEncoding
            self.altText = altText
        }
    }

    public let formatVersion: Int = 1
    public var passTypeIdentifier: String
    public var teamIdentifier: String
    /// Unique per pass type. The DID: one pass per account, so re-adding
    /// with a new theme replaces the card instead of stacking a second.
    public var serialNumber: String
    public var organizationName: String
    /// Accessibility description, read aloud by VoiceOver.
    public var description: String
    public var backgroundColor: String
    public var foregroundColor: String
    public var labelColor: String
    public var barcodes: [Barcode]
    public var generic: FieldSet
    public var posterGeneric: FieldSet
    /// App Store IDs listed on the back of the pass; the first one that's
    /// installed gets the "open app" link.
    public var associatedStoreIdentifiers: [Int]?
    public var suppressHeaderDarkening: Bool = false
    public var useAutomaticColors: Bool = false
    public var sharingProhibited: Bool = false

    public init(passTypeIdentifier: String, teamIdentifier: String, serialNumber: String, organizationName: String, description: String, backgroundColor: String, foregroundColor: String, labelColor: String, barcodes: [Barcode], generic: FieldSet, posterGeneric: FieldSet, associatedStoreIdentifiers: [Int]? = nil) {
        self.passTypeIdentifier = passTypeIdentifier
        self.teamIdentifier = teamIdentifier
        self.serialNumber = serialNumber
        self.organizationName = organizationName
        self.description = description
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.labelColor = labelColor
        self.barcodes = barcodes
        self.generic = generic
        self.posterGeneric = posterGeneric
        self.associatedStoreIdentifiers = associatedStoreIdentifiers
    }

    // MARK: Profile pass

    /// The web address the QR code carries. The handle form is what people
    /// expect to see when a scanner previews it; a pass is easy to remake
    /// after a handle change.
    public static func profileURL(handle: String) -> String {
        "https://bsky.app/profile/\(handle)"
    }

    /// Builds the profile pass for an account.
    public static func profile(
        handle: String,
        did: String,
        memberSince: Date?,
        theme: WalletPassTheme,
        passTypeIdentifier: String,
        teamIdentifier: String,
        organizationName: String = "Atmo",
        appStoreID: Int? = nil
    ) -> WalletPassDocument {
        let handleField = Field(key: "handle", label: "Handle", value: handle)
        var sinceField: Field? = nil
        if let memberSince {
            sinceField = Field(key: "since", label: "Member Since", value: iso8601(memberSince), dateStyle: "PKDateStyleShort")
        }
        let didField = Field(key: "did", value: did, textAlignment: "PKTextAlignmentNatural")

        let generic = FieldSet(
            primaryFields: [handleField],
            secondaryFields: sinceField.map { [$0] } ?? [],
            backFields: [Field(key: "did-back", label: "DID", value: did)]
        )
        let poster = FieldSet(
            primaryFields: [handleField] + (sinceField.map { [$0] } ?? []),
            footerFields: [didField],
            backFields: [Field(key: "did-back", label: "DID", value: did)]
        )

        return WalletPassDocument(
            passTypeIdentifier: passTypeIdentifier,
            teamIdentifier: teamIdentifier,
            serialNumber: did,
            organizationName: organizationName,
            description: "Bluesky profile of @\(handle)",
            backgroundColor: theme.backgroundColor.cssString,
            foregroundColor: theme.foregroundColor.cssString,
            labelColor: theme.labelColor.cssString,
            barcodes: [Barcode(message: profileURL(handle: handle), altText: handle)],
            generic: generic,
            posterGeneric: poster,
            associatedStoreIdentifiers: appStoreID.map { [$0] }
        )
    }

    /// `pass.json` bytes — sorted keys, unescaped slashes.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
