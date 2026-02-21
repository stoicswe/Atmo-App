import SwiftUI

enum AtmoFonts {
    // MARK: - Display
    static let appTitle = Font.system(size: 40, weight: .bold, design: .rounded)
    static let sectionTitle = Font.system(size: 22, weight: .bold, design: .rounded)

    // MARK: - Body
    static let body = Font.body
    static let bodyMedium = Font.body.weight(.medium)
    static let bodySemibold = Font.body.weight(.semibold)

    // MARK: - UI
    static let handle = Font.system(.subheadline, design: .monospaced)
    static let timestamp = Font.caption
    static let characterCount = Font.system(.callout, design: .monospaced)

    // MARK: - Post
    static let postText = Font.body
    static let authorName = Font.subheadline.weight(.semibold)
    static let authorHandle = Font.subheadline

    // MARK: - Actions
    static let actionCount = Font.caption.weight(.medium)
}
