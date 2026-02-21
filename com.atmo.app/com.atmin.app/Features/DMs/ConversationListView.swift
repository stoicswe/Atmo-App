import SwiftUI

struct ConversationListView: View {
    @Environment(ATProtoService.self) private var service
    @State private var viewModel: DMsViewModel?

    /// Set to true when embedded in AppNavigation's shared NavigationStack (iPad/macOS).
    /// When false (iPhone), this view wraps itself in its own NavigationStack.
    var embeddedInSplitView: Bool = false

    var body: some View {
        let content = Group {
            if let vm = viewModel {
                conversationList(vm: vm)
            } else {
                LoadingView(message: "Loading messages…")
            }
        }
        .task {
            if viewModel == nil {
                viewModel = DMsViewModel(service: service)
            }
            await viewModel?.load()
        }

        if embeddedInSplitView {
            content
        } else {
            NavigationStack {
                content
                    .navigationTitle("Messages")
#if os(iOS)
                    .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
#endif
                    .navigationDestination(for: ConversationItem.self) { convo in
                        ConversationDetailView(conversation: convo)
                    }
            }
        }
    }

    @ViewBuilder
    private func conversationList(vm: DMsViewModel) -> some View {
        if vm.isLoading && vm.conversations.isEmpty {
            LoadingView(message: "Loading messages…")
        } else if vm.conversations.isEmpty {
            ContentUnavailableView(
                "No Messages",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Your direct messages will appear here.")
            )
        } else {
            List(vm.conversations) { convo in
                NavigationLink(value: convo) {
                    ConversationRowView(conversation: convo)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .refreshable { await vm.load() }
            .navigationDestination(for: ConversationItem.self) { convo in
                ConversationDetailView(conversation: convo)
            }
        }
    }
}

// MARK: - Conversation Row
private struct ConversationRowView: View {
    let conversation: ConversationItem

    var otherParticipants: [ConversationItem.ParticipantInfo] {
        // In a group DM there may be many; for now take first 3
        Array(conversation.participants.prefix(3))
    }

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.md) {
            // Avatar stack (up to 2)
            ZStack {
                ForEach(Array(otherParticipants.prefix(2).enumerated()), id: \.element.did) { index, p in
                    AvatarView(url: p.avatarURL, size: 44)
                        .offset(x: CGFloat(index) * 14, y: CGFloat(index) * 8)
                }
            }
            .frame(width: 60, height: 50)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(otherParticipants.map { $0.displayName ?? $0.handle }.joined(separator: ", "))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if let lastAt = conversation.lastMessageAt {
                        Text(lastAt.atmoFormatted())
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let lastMessage = conversation.lastMessage {
                    Text(lastMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AtmoColors.skyBlue)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, AtmoTheme.Spacing.xs)
    }
}
