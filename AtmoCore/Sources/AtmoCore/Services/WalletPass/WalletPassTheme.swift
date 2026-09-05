import Foundation

// MARK: - WalletPassTheme
/// A look for the Wallet profile pass: the card colours Wallet paints
/// behind the text, plus the artwork that fills the poster layout. The
/// artwork bytes themselves are bundled by the app (PNG files named
/// after the theme id); AtmoCore only names and describes them.
public struct WalletPassTheme: Identifiable, Hashable, Sendable, Codable {

    /// An 8-bit colour in pass.json's `rgb(r, g, b)` syntax.
    public struct RGB: Hashable, Sendable, Codable {
        public var red: Int
        public var green: Int
        public var blue: Int

        public init(_ red: Int, _ green: Int, _ blue: Int) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public var cssString: String { "rgb(\(red), \(green), \(blue))" }
    }

    /// Stable identifier; doubles as the artwork folder name in the app
    /// bundle (`WalletPass/Themes/<id>/artwork@2x.png`).
    public let id: String
    public let name: String
    /// Painted behind the fields; also the fallback when the artwork
    /// can't be shown.
    public let backgroundColor: RGB
    /// Field values.
    public let foregroundColor: RGB
    /// Field labels.
    public let labelColor: RGB
    /// Who made the artwork — shown under the preview so the photographer
    /// is credited wherever the picture appears.
    public let credit: String?
    /// Where the credit points (the photographer's page), if anywhere.
    public let creditURL: URL?

    public init(id: String, name: String, backgroundColor: RGB, foregroundColor: RGB, labelColor: RGB, credit: String? = nil, creditURL: URL? = nil) {
        self.id = id
        self.name = name
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.labelColor = labelColor
        self.credit = credit
        self.creditURL = creditURL
    }

    // MARK: Photography
    // Every built-in theme's artwork is a photograph by yujeong Huh, used
    // with permission.
    public static let photographerCredit = "Photo by yujeong Huh"
    public static let photographerURL = URL(string: "https://instagram.com/voyagerh_0000")

    // MARK: Built-in themes
    // Order is the order the picker shows them. Artwork placeholders for
    // each id live in Resources/WalletPass/Themes/<id>/ — swap the PNGs
    // for stock photos (and fill in `credit`) without touching code.

    public static let sky = WalletPassTheme(
        id: "sky", name: "Sky",
        backgroundColor: RGB(36, 118, 214),
        foregroundColor: RGB(255, 255, 255),
        labelColor: RGB(222, 235, 255),
        credit: photographerCredit, creditURL: photographerURL
    )

    public static let dusk = WalletPassTheme(
        id: "dusk", name: "Dusk",
        backgroundColor: RGB(70, 44, 120),
        foregroundColor: RGB(255, 255, 255),
        labelColor: RGB(233, 214, 255),
        credit: photographerCredit, creditURL: photographerURL
    )

    public static let forest = WalletPassTheme(
        id: "forest", name: "Forest",
        backgroundColor: RGB(24, 86, 62),
        foregroundColor: RGB(255, 255, 255),
        labelColor: RGB(206, 238, 220),
        credit: photographerCredit, creditURL: photographerURL
    )

    public static let graphite = WalletPassTheme(
        id: "graphite", name: "Graphite",
        backgroundColor: RGB(38, 40, 46),
        foregroundColor: RGB(255, 255, 255),
        labelColor: RGB(190, 194, 204),
        credit: photographerCredit, creditURL: photographerURL
    )

    public static let sea = WalletPassTheme(
        id: "sea", name: "Sea",
        backgroundColor: RGB(12, 84, 122),
        foregroundColor: RGB(255, 255, 255),
        labelColor: RGB(200, 234, 245),
        credit: photographerCredit, creditURL: photographerURL
    )

    public static let blossom = WalletPassTheme(
        id: "blossom", name: "Blossom",
        backgroundColor: RGB(176, 86, 122),
        foregroundColor: RGB(255, 255, 255),
        labelColor: RGB(255, 226, 238),
        credit: photographerCredit, creditURL: photographerURL
    )

    public static let builtIn: [WalletPassTheme] = [sky, dusk, forest, graphite, sea, blossom]

    public static func builtIn(id: String) -> WalletPassTheme? {
        builtIn.first { $0.id == id }
    }
}
