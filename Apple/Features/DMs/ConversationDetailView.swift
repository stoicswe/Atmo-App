import SwiftUI
import AtmoCore

struct ConversationDetailView: View {
    let conversation: ConversationItem
    @Environment(ATProtoService.self) private var service
    @State private var viewModel: ConversationDetailViewModel?
    @State private var messageText: String = ""
    @FocusState private var isInputFocused: Bool

    var otherParticipant: ConversationItem.ParticipantInfo? {
        conversation.participants.first { $0.did != service.currentUserDID }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages scroll area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let vm = viewModel {
                            ForEach(vm.messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    isFromMe: message.senderDID == service.currentUserDID
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.vertical, AtmoTheme.Spacing.md)
                }
                .onChange(of: viewModel?.messages.count) { _, _ in
                    if let lastID = viewModel?.messages.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }

            // Input bar in the app bottom bar's visual language (which
            // steps aside while a conversation is open): a glass text
            // capsule where the tab pill sits, and a separate glass send
            // circle where the compose button sits.
            HStack(spacing: AtmoTheme.Spacing.md) {
                TextField("Message…", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .lineLimit(1...4)
                    .padding(.horizontal, AtmoTheme.Spacing.lg)
                    .padding(.vertical, AtmoTheme.Spacing.sm)
                    .frame(minHeight: 48)
                    .glassEffect(.regular, in: RoundedRectangle(
                        cornerRadius: AtmoTheme.CornerRadius.pill, style: .continuous))

                Button {
                    let text = messageText
                    messageText = ""
                    Task { await viewModel?.sendMessage(text: text) }
                } label: {
                    let canSend = !messageText
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Image(systemName: "arrow.up")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(canSend ? AtmoColors.accent : Color.secondary)
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, AtmoTheme.Spacing.lg)
            .padding(.vertical, AtmoTheme.Spacing.sm)
        }
        .navigationTitle(otherParticipant?.displayName ?? otherParticipant?.handle ?? "Chat")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .task {
            if viewModel == nil {
                viewModel = ConversationDetailViewModel(
                    conversationID: conversation.convoID,
                    service: service
                )
            }
            await viewModel?.load()
        }
    }
}
