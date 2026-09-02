import SwiftUI

// MARK: - Attachment Menu
/// The iMessage "+" menu: a tall glass panel that springs up from the
/// plus button, one row per option — a colored icon disc and a large
/// label. Rows call their action; the host closes the panel.
struct AttachmentMenuItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
}

struct AttachmentMenuPanel: View {
    let items: [AttachmentMenuItem]
    /// Optional note under the rows (e.g. what this channel can't carry).
    var footer: String? = nil
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                Button {
                    Haptics.tap()
                    onSelect()
                    item.action()
                } label: {
                    HStack(spacing: AtmoTheme.Spacing.lg) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(item.tint, in: Circle())
                        Text(item.title)
                            .font(.title3)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AtmoTheme.Spacing.lg)
                    .padding(.vertical, AtmoTheme.Spacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AtmoTheme.Spacing.lg)
                    .padding(.top, AtmoTheme.Spacing.xs)
                    .padding(.bottom, AtmoTheme.Spacing.md)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, AtmoTheme.Spacing.sm)
        .frame(width: 300)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }
}
