import SwiftUI
import Combine
import AtmoCore

// MARK: - GhostsView
// The Ghosts library section (shown only while the feature is on): every
// ghost the user has posted from this app. Live ones list first with the
// time they have left — tapping opens the thread, the context menu ends
// one early. Ended ones sit below in the archive with their text, since
// the post itself is gone from Bluesky.
struct GhostsView: View {

    /// When non-nil (iPad/macOS split view), navigation uses the shared parent
    /// NavigationStack in AppNavigation. When nil (iPhone), owns its own stack.
    var splitNavPath: Binding<NavigationPath>? = nil
    @State private var ownedNavPath = NavigationPath()

    @Environment(ATProtoService.self) private var service
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var navPath: Binding<NavigationPath> {
        splitNavPath ?? $ownedNavPath
    }

    var body: some View {
        if splitNavPath != nil {
            ghostsContent
        } else {
            NavigationStack(path: $ownedNavPath) {
                ghostsContent
                    .navigationTitle("Ghosts")
#if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .navigationDestination(for: PostNavTarget.self) { target in
                        ThreadView(postURI: target.uri)
                            .themedBackdrop()
                    }
                    .themedBackdrop()
            }
        }
    }

    // MARK: - Content

    /// The signed-in account, for the row header — ghosts are always ours.
    private var me: AccountProfileCache.Snapshot? {
        service.currentUserDID.flatMap { AccountProfileCache.shared.snapshot(for: $0) }
    }

    @ViewBuilder
    private var ghostsContent: some View {
        let store = GhostPostStore.shared
        Group {
            if store.active.isEmpty && store.archive.isEmpty {
                ContentUnavailableView(
                    "No Ghosts Yet",
                    systemImage: "moon.haze",
                    description: Text("Ghosts you post will gather here while they're up, then move to the archive once they fade.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !store.active.isEmpty {
                            sectionHeader("Live", count: store.active.count)
                            ForEach(store.active) { entry in
                                GhostRow(entry: entry, me: me, handle: service.currentHandle, now: now)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        navPath.wrappedValue = NavigationPath([PostNavTarget(uri: entry.uri)])
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            Haptics.soft()
                                            Task { await store.endNow(uri: entry.uri, service: service) }
                                        } label: {
                                            Label("End Now", systemImage: "moon.haze")
                                        }
                                        .disabled(store.isCleaningUp)
                                    }
                                Divider().overlay(Color.secondary.opacity(0.1))
                            }
                        }

                        if !store.archive.isEmpty {
                            sectionHeader("Ended", count: store.archive.count)
                            ForEach(store.archive) { entry in
                                GhostRow(entry: entry, me: me, handle: service.currentHandle, now: now)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            withAnimation { store.removeFromArchive(uri: entry.uri) }
                                        } label: {
                                            Label("Remove from Archive", systemImage: "trash")
                                        }
                                    }
                                Divider().overlay(Color.secondary.opacity(0.1))
                            }
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: store.active.count)
                }
            }
        }
        .onReceive(clock) { now = $0 }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.top, AtmoTheme.Spacing.lg)
        .padding(.bottom, AtmoTheme.Spacing.xs)
    }
}

// MARK: - Ghost Row
/// Mirrors the Liked row: our avatar and name, the ghost's text, and a
/// footer with its clock (live) or when it ended (archived).
private struct GhostRow: View {
    let entry: GhostPostEntry
    let me: AccountProfileCache.Snapshot?
    let handle: String?
    let now: Date

    private var isLive: Bool { entry.endedAt == nil }

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {
            AvatarView(url: me?.avatarURL, size: AtmoTheme.Feed.avatarSize)
                .opacity(isLive ? 1 : 0.6)

            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    if let name = me?.displayName, !name.isEmpty {
                        Text(name)
                            .font(AtmoFonts.authorName)
                            .lineLimit(1)
                    }
                    if let handle = me?.handle ?? handle {
                        Text("@\(handle)")
                            .font(AtmoFonts.authorHandle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(entry.createdAt.atmoFormatted())
                        .font(AtmoFonts.timestamp)
                        .foregroundStyle(.tertiary)
                }

                Text(entry.text.isEmpty ? "(media only)" : entry.text)
                    .font(.subheadline)
                    .foregroundStyle(isLive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(3)

                HStack(spacing: 4) {
                    Image(systemName: "moon.haze.fill")
                        .font(.caption2)
                        .foregroundStyle(isLive ? AnyShapeStyle(AtmoColors.accent) : AnyShapeStyle(.tertiary))
                    if isLive {
                        Text(GhostPostPolicy.remainingText(until: entry.expiresAt, now: now))
                            .font(.caption2)
                            .foregroundStyle(AtmoColors.accent)
                    } else if let ended = entry.endedAt {
                        Text("Ended \(ended.atmoFormatted())")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Feed.verticalPadding)
    }
}
