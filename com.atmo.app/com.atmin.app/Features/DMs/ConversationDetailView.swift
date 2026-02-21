import SwiftUI

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

            Divider().overlay(AtmoColors.glassDivider)

            // Input bar
            HStack(spacing: AtmoTheme.Spacing.md) {
                TextField("Message…", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .lineLimit(1...4)
                    .padding(.horizontal, AtmoTheme.Spacing.md)
                    .padding(.vertical, AtmoTheme.Spacing.sm)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.pill, style: .continuous))

                Button {
                    let text = messageText
                    messageText = ""
                    Task { await viewModel?.sendMessage(text: text) }
                } label: {
                    let iconColor: Color = messageText.isEmpty ? .secondary : AtmoColors.skyBlue
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(iconColor)
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(AtmoTheme.Spacing.md)
            .background(.regularMaterial)
        }
        .navigationTitle(otherParticipant?.displayName ?? otherParticipant?.handle ?? "Chat")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
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
