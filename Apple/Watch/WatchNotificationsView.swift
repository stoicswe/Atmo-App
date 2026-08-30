import SwiftUI
import AtmoCore

struct WatchNotificationsView: View {
    @Environment(ATProtoService.self) private var service
    @State private var viewModel: NotificationsViewModel? = nil

    var body: some View {
        Group {
            if let viewModel {
                if viewModel.notifications.isEmpty && viewModel.isLoading {
                    ProgressView()
                } else if viewModel.notifications.isEmpty {
                    Text("No activity yet")
                        .foregroundStyle(.secondary)
                } else {
                    List(viewModel.notifications) { notification in
                        WatchNotificationRow(notification: notification)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task {
            if viewModel == nil {
                let vm = NotificationsViewModel(service: service)
                viewModel = vm
                await vm.load()
            }
        }
    }
}

struct WatchNotificationRow: View {
    let notification: NotificationItem

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: notification.reason.icon)
                .font(.caption)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.authorDisplayName ?? notification.authorHandle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text(notification.reason.displayText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(notification.indexedAt.atmoFormatted())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
