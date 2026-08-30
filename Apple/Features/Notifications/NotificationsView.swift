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
            NavigationStack {
                content
                    .navigationTitle("Activity")
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
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
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
// Capsule filter tab, visually matched to Search's category chips.
private struct ActivityPill: View {
    let category: ActivityCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
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
    }
}
