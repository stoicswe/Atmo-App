import SwiftUI
import AtmoCore

// MARK: - LikedPostsView
// The ♥ library section: every post the user liked from this app,
// newest first — recorded by LikedPostsStore as likes land and synced
// via iCloud KVS (like bookmarks, invisible in iCloud Drive). Tapping a
// row opens the thread; the context menu removes an entry from the
// history (without touching the like on Bluesky).
struct LikedPostsView: View {

    /// When non-nil (iPad/macOS split view), navigation uses the shared parent
    /// NavigationStack in AppNavigation. When nil (iPhone), owns its own stack.
    var splitNavPath: Binding<NavigationPath>? = nil
    @State private var ownedNavPath = NavigationPath()

    @Environment(ATProtoService.self) private var service

    /// Live scrub state published by the rail — drives the date bubble.
    @State private var railDragInfo: RailDragInfo? = nil

    private var navPath: Binding<NavigationPath> {
        splitNavPath ?? $ownedNavPath
    }

    var body: some View {
        if splitNavPath != nil {
            likedContent
        } else {
            NavigationStack(path: $ownedNavPath) {
                likedContent
                    .navigationTitle("Liked")
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

    @ViewBuilder
    private var likedContent: some View {
        let store = LikedPostsStore.shared
        Group {
            if store.likedPosts.isEmpty {
                VStack(spacing: AtmoTheme.Spacing.md) {
                    ContentUnavailableView(
                        "No Liked Posts Yet",
                        systemImage: "heart",
                        description: Text("Posts you like will collect here so you can look back on them.")
                    )
                    if store.isBackfilling {
                        syncingFooter
                    }
                }
            } else {
                let markers = LikedTimelineIndex.markers(for: store.likedPosts)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.likedPosts) { liked in
                                LikedPostRow(liked: liked)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        navPath.wrappedValue = NavigationPath([PostNavTarget(uri: liked.uri)])
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            withAnimation {
                                                store.remove(uri: liked.uri)
                                            }
                                        } label: {
                                            Label("Remove from History", systemImage: "heart.slash")
                                        }
                                    }
                                Divider().overlay(Color.secondary.opacity(0.1))
                            }

                            if store.isBackfilling {
                                syncingFooter
                                    .padding(.vertical, AtmoTheme.Spacing.lg)
                            }
                        }
                    }
                    // ── Timeline rail ──
                    // Photos-style date scrubber: tap or drag along the
                    // trailing edge to jump days/months/years through the
                    // history (granularity adapts to its span).
                    .overlay(alignment: .trailing) {
                        if markers.count >= 3 {
                            LikedTimelineRail(markers: markers, dragInfo: $railDragInfo) { marker in
                                proxy.scrollTo(marker.id, anchor: .top)
                            }
                            .padding(.vertical, AtmoTheme.Spacing.xl)
                            .padding(.trailing, 2)
                        }
                    }
                    // Floating date bubble beside the finger while scrubbing.
                    .overlay(alignment: .topTrailing) {
                        if let info = railDragInfo {
                            Text(info.label)
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .padding(.horizontal, AtmoTheme.Spacing.md)
                                .padding(.vertical, AtmoTheme.Spacing.sm)
                                .glassEffect(.regular, in: Capsule())
                                .padding(.trailing, 44)
                                .offset(y: info.y + AtmoTheme.Spacing.xl - 14)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
        // Trickle in past likes (posts only) from the account's own like
        // records — a few pages per visit, cursor-resumed across visits.
        .task(id: service.currentUserDID) {
            await LikedPostsStore.shared.continueBackfill(service: service)
        }
    }

    private var syncingFooter: some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Syncing past likes…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Rail Drag Info
/// What the rail reports while the finger scrubs: the bubble text and its
/// vertical position within the rail.
struct RailDragInfo: Equatable {
    let label: String
    let y: CGFloat
}

// MARK: - Liked Timeline Rail
// The scrubber strip on the list's trailing edge: one slot per timeline
// marker (period labels; boundaries in accent). A tap jumps; a drag skims
// through periods with a tick per marker crossed, the active label
// swelling under the finger.
private struct LikedTimelineRail: View {
    let markers: [LikedTimelineMarker]
    @Binding var dragInfo: RailDragInfo?
    let onJump: (LikedTimelineMarker) -> Void

    @State private var isDragging = false
    @State private var activeIndex: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let rowHeight = geo.size.height / CGFloat(markers.count)

            VStack(spacing: 0) {
                ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                    Text(marker.label)
                        .font(.system(size: 9, weight: marker.isMajor ? .bold : .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(marker.isMajor
                                         ? AnyShapeStyle(AtmoColors.accent)
                                         : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .frame(height: rowHeight)
                        .scaleEffect(isDragging && activeIndex == index ? 1.5 : 1)
                        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: activeIndex)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let index = min(max(Int(value.location.y / rowHeight), 0), markers.count - 1)
                        if index != activeIndex {
                            activeIndex = index
                            Haptics.slideSelect()
                            onJump(markers[index])
                        }
                        dragInfo = RailDragInfo(
                            label: markers[index].fullLabel,
                            y: min(max(value.location.y, 0), geo.size.height)
                        )
                    }
                    .onEnded { _ in
                        isDragging = false
                        activeIndex = nil
                        dragInfo = nil
                    }
            )
        }
        .frame(width: 30)
        .background {
            // A whisper of glass while scrubbing so the strip reads as a
            // control; invisible at rest.
            if isDragging {
                Capsule().fill(.ultraThinMaterial)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDragging)
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityHint("Drag to jump through your liked history by date")
    }
}

// MARK: - Liked Post Row
private struct LikedPostRow: View {
    let liked: LikedPost

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {
            AvatarView(url: liked.authorAvatarURL, size: AtmoTheme.Feed.avatarSize)

            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    if let name = liked.authorDisplayName {
                        Text(name)
                            .font(AtmoFonts.authorName)
                            .lineLimit(1)
                    }
                    Text("@\(liked.authorHandle)")
                        .font(AtmoFonts.authorHandle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(liked.indexedAt.atmoFormatted())
                        .font(AtmoFonts.timestamp)
                        .foregroundStyle(.tertiary)
                }

                if !liked.text.isEmpty {
                    Text(liked.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }

                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(AtmoColors.likeRed)
                    Text("Liked \(liked.likedAt.atmoFormatted())")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Feed.verticalPadding)
    }
}
