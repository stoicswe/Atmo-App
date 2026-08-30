import SwiftUI
import AtmoCore

// MARK: - DraftsView
// Shows all saved composer drafts. Tapping a row fires onOpenDraft so the
// parent (AppNavigation) can open the composer sheet with the selected draft.
// Swiping left deletes a draft immediately.
struct DraftsView: View {

    /// When non-nil (iPad/macOS split view), navigation uses the shared parent
    /// NavigationStack in AppNavigation. When nil (iPhone), owns its own stack.
    var splitNavPath: Binding<NavigationPath>? = nil
    @State private var ownedNavPath = NavigationPath()

    /// Called when the user taps a draft row — bubble up to AppNavigation so
    /// the sheet can be opened at the correct level in the view hierarchy.
    var onOpenDraft: ((ComposerDraft) -> Void)? = nil

    private var navPath: Binding<NavigationPath> {
        splitNavPath ?? $ownedNavPath
    }

    var body: some View {
        if splitNavPath != nil {
            draftsContent
        } else {
            NavigationStack(path: $ownedNavPath) {
                draftsContent
                    .navigationTitle("Drafts")
#if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .navigationDestination(for: PostNavTarget.self) { target in
                        ThreadView(postURI: target.uri)
                    }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var draftsContent: some View {
        let store = DraftStore.shared
        if store.drafts.isEmpty {
            emptyState
        } else {
            // A real List — swipeActions are inert inside a plain
            // ScrollView/LazyVStack, which left drafts undeletable.
            List {
                ForEach(store.drafts) { draft in
                    DraftRowView(draft: draft)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpenDraft?(draft) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                withAnimation {
                                    store.delete(id: draft.id)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        // Right-click / long-press fallback, mainly for macOS
                        // where swipe is less discoverable.
                        .contextMenu {
                            Button(role: .destructive) {
                                withAnimation {
                                    store.delete(id: draft.id)
                                }
                            } label: {
                                Label("Delete Draft", systemImage: "trash")
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparatorTint(Color.secondary.opacity(0.1))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Drafts",
            systemImage: "doc.text",
            description: Text("Posts you start but don't send will be saved here.")
        )
    }
}

// MARK: - DraftRowView
// Compact row: an icon, context/thread metadata, text preview, and timestamp.
private struct DraftRowView: View {
    let draft: ComposerDraft

    private var previewText: String {
        draft.posts.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var contextLabel: String? {
        if draft.replyToURI != nil    { return "Reply" }
        if draft.quotedPostURI != nil { return "Quote" }
        return nil
    }

    private var threadLabel: String? {
        draft.posts.count > 1 ? "\(draft.posts.count) posts" : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {

            // Icon badge
            ZStack {
                Circle()
                    .fill(AtmoColors.accent.opacity(0.12))
                    .frame(width: AtmoTheme.Feed.avatarSize, height: AtmoTheme.Feed.avatarSize)
                Image(systemName: iconName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AtmoColors.accent)
            }

            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {

                // Meta row: context + thread count + timestamp
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    if let ctx = contextLabel {
                        Text(ctx)
                            .font(AtmoFonts.authorHandle)
                            .foregroundStyle(AtmoColors.accent)
                        Text("·")
                            .font(AtmoFonts.authorHandle)
                            .foregroundStyle(.tertiary)
                    }
                    if let tl = threadLabel {
                        Text(tl)
                            .font(AtmoFonts.authorHandle)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(AtmoFonts.authorHandle)
                            .foregroundStyle(.tertiary)
                    }
                    if contextLabel == nil && threadLabel == nil {
                        Text("Draft")
                            .font(AtmoFonts.authorHandle)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(draft.modifiedAt.atmoFormatted())
                        .font(AtmoFonts.timestamp)
                        .foregroundStyle(.tertiary)
                }

                // First post preview
                if !previewText.isEmpty {
                    Text(previewText)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }

                // Subsequent slots (thread continuation previews)
                if draft.posts.count > 1 {
                    ForEach(draft.posts.dropFirst()) { post in
                        let t = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty {
                            HStack(alignment: .top, spacing: AtmoTheme.Spacing.xs) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(width: 2, height: 14)
                                    .padding(.leading, 5)
                                Text(t)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Feed.verticalPadding)
    }

    private var iconName: String {
        if draft.replyToURI != nil    { return "arrowshape.turn.up.left" }
        if draft.quotedPostURI != nil { return "quote.bubble" }
        if draft.posts.count > 1     { return "list.bullet.rectangle" }
        return "doc.text"
    }
}
