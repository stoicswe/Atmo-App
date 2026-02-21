import SwiftUI

struct NotificationsView: View {
    @Environment(ATProtoService.self) private var service
    @State private var viewModel: NotificationsViewModel?

    /// Set to true when embedded in AppNavigation's shared NavigationStack (iPad/macOS).
    /// When false (iPhone), this view wraps itself in its own NavigationStack.
    var embeddedInSplitView: Bool = false

    var body: some View {
        let content = Group {
            if let vm = viewModel {
                notificationsList(vm: vm)
            } else {
                LoadingView(message: "Loading notifications…")
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
                    .navigationTitle("Notifications")
#if os(iOS)
                    .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
#endif
            }
        }
    }

    @ViewBuilder
    private func notificationsList(vm: NotificationsViewModel) -> some View {
        if vm.isLoading && vm.notifications.isEmpty {
            LoadingView(message: "Loading notifications…")
        } else if vm.notifications.isEmpty {
            ContentUnavailableView(
                "No Notifications",
                systemImage: "bell.slash",
                description: Text("You're all caught up.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.notifications) { notification in
                        NotificationRowView(notification: notification)
                        Divider().overlay(Color.secondary.opacity(0.1))
                            .onAppear {
                                if notification.id == vm.notifications.last?.id {
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
