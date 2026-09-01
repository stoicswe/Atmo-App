import SwiftUI
import AtmoCore

// MARK: - Activity
// The Activity section: one feed of everything that happened to the
// account, filtered by pill tabs — Notifications (all), then one pill per
// Bluesky notification reason (Follows, Replies, Mentions, Quotes,
// Reposts, Likes). Filtering happens client-side in the view model, so
// switching pills is instant.
struct NotificationsView: View {
    @Environment(ATProtoService.self) private var service
    @State private var viewModel: NotificationsViewModel?
    /// Path for the standalone-stack fallback below; unused when embedded.
    @State private var ownedNavPath = NavigationPath()

    /// Set to true when embedded in AppNavigation's shared NavigationStack (iPad/macOS).
    /// When false (iPhone), this view wraps itself in its own NavigationStack.
    var embeddedInSplitView: Bool = false

    var body: some View {
        let content = Group {
            if let vm = viewModel {
                activityContent(vm: vm)
            } else {
                LoadingView(message: "Loading activity…")
            }
        }
        .task {
            if viewModel == nil {
                viewModel = NotificationsViewModel(service: service)
            }
            await viewModel?.load()
        }

        if embeddedInSplitView {
            content
        } else {
            NavigationStack(path: $ownedNavPath) {
                content
                    .navigationTitle("Activity")
                    // Row links (avatar → profile) need destinations on
                    // THIS stack when the view owns one.
                    .navigationDestination(for: PostNavTarget.self) { target in
                        ThreadView(postURI: target.uri)
                            .themedBackdrop()
                    }
                    .navigationDestination(for: String.self) { did in
                        ProfileView(actorDID: did, splitNavPath: $ownedNavPath)
                            .themedBackdrop()
                    }
                    .themedBackdrop()
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func activityContent(vm: NotificationsViewModel) -> some View {
        VStack(spacing: 0) {
            categoryPills(vm: vm)
                .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
                .padding(.vertical, AtmoTheme.Spacing.sm)

            Divider().overlay(Color.secondary.opacity(0.08))

            activityList(vm: vm)
        }
    }

    // MARK: - Pill tabs

    private func categoryPills(vm: NotificationsViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AtmoTheme.Spacing.sm) {
                ForEach(ActivityCategory.allCases) { category in
                    ActivityPill(
                        category: category,
                        isSelected: vm.selectedCategory == category
                    ) {
                        // Tap-and-slide only when the selection actually
                        // moves — re-tapping the open chip stays silent.
                        if vm.selectedCategory != category { Haptics.slideSelect() }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            vm.selectedCategory = category
                        }
                    }
                }
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private func activityList(vm: NotificationsViewModel) -> some View {
        let items = vm.filteredNotifications
        if vm.isLoading && vm.notifications.isEmpty {
            LoadingView(message: "Loading activity…")
        } else if items.isEmpty {
            ContentUnavailableView(
                vm.selectedCategory == .notifications
                    ? "No Notifications"
                    : "No \(vm.selectedCategory.rawValue)",
                systemImage: vm.selectedCategory == .notifications
                    ? "bell.slash"
                    : vm.selectedCategory.icon,
                description: Text(
                    vm.selectedCategory == .notifications
                        ? "You're all caught up."
                        : "Nothing here yet — new \(vm.selectedCategory.rawValue.lowercased()) will appear in this tab."
                )
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { notification in
                        NotificationRowView(notification: notification)
                        Divider().overlay(Color.secondary.opacity(0.1))
                            // Page in more once the end of the *filtered* list
                            // appears — narrow filters may need several pages
                            // to fill.
                            .onAppear {
                                if notification.id == items.last?.id {
                                    Task { await vm.loadMore() }
                                }
                            }
                    }
                }
            }
            .refreshable {
                await vm.load()
            }
        }
    }
}

// MARK: - Activity Pill
// iOS: Mail-style category chip — a compact icon circle that expands into
// a tinted capsule with its label when selected (matches Settings' top
// bar). macOS keeps the always-labeled capsule tabs.
private struct ActivityPill: View {
    let category: ActivityCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
#if os(iOS)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.system(size: 15, weight: .medium))
                if isSelected {
                    Text(category.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .padding(.horizontal, isSelected ? AtmoTheme.Spacing.lg : 0)
            .frame(height: 40)
            .frame(minWidth: 40)
            .background {
                Capsule().fill(isSelected ? AtmoColors.accent : Color.secondary.opacity(0.12))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
#else
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: category.icon)
                    .font(.caption.weight(.medium))
                Text(category.rawValue)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isSelected ? .white : .secondary)
            .padding(.horizontal, AtmoTheme.Spacing.md)
            .padding(.vertical, AtmoTheme.Spacing.xs)
            .background {
                Capsule()
                    .fill(isSelected ? AtmoColors.accent : Color.secondary.opacity(0.1))
            }
        }
        .buttonStyle(.plain)
#endif
    }
}
