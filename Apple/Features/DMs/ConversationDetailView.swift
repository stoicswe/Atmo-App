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

    /// iPhone: the app's bottom bar morphs into the composer (field + send
    /// arrow), so this view draws no input of its own there. iPad/macOS
    /// keep the inline bar.
    private var usesAppBarComposer: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
#else
        false
#endif
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages scroll area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let vm = viewModel {
                            ForEach(Array(vm.messages.enumerated()), id: \.element.id) { index, message in
                                MessageBubbleView(
                                    message: message,
                                    isFromMe: message.senderDID == service.currentUserDID,
                                    showsTimestamp: vm.showsTimestamp(at: index)
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.vertical, AtmoTheme.Spacing.md)
                }
                // Chat-style anchoring: open at the newest message and stay
                // pinned to the bottom as content or insets (keyboard, bar)
                // change while the user is there.
                .defaultScrollAnchor(.bottom)
                .onChange(of: viewModel?.messages.count) { _, _ in
                    guard let lastID = viewModel?.messages.last?.id else { return }
                    // Next tick, so the appended bubble has a laid-out frame —
                    // scrolling to an estimated position left the fresh bubble
                    // stranded below the visible bottom, behind the input bar.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }

            // Inline input bar — iPad/macOS only; the iPhone's app bottom
            // bar becomes the composer instead (see usesAppBarComposer).
            if !usesAppBarComposer {
                inlineInputBar
            }
        }
        .navigationTitle(otherParticipant?.displayName ?? otherParticipant?.handle ?? "Chat")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // Hand the bottom bar back to the app when leaving.
            guard usesAppBarComposer else { return }
            let chrome = PhoneChromeState.shared
            chrome.dmSend = nil
            chrome.dmDraft = ""
        }
#endif
        .task {
            if viewModel == nil {
                viewModel = ConversationDetailViewModel(
                    conversationID: conversation.convoID,
                    service: service
                )
            }
#if os(iOS)
            // Registered here (not onAppear) so the view model exists when
            // the closure is built; the bar morphs into the composer the
            // moment dmSend becomes non-nil.
            if usesAppBarComposer, let vm = viewModel {
                let chrome = PhoneChromeState.shared
                chrome.dmDraft = ""
                chrome.dmSend = { [weak vm] in
                    guard let vm else { return }
                    let text = PhoneChromeState.shared.dmDraft
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    PhoneChromeState.shared.dmDraft = ""
                    Task { await vm.sendMessage(text: text) }
                }
            }
#endif
            await viewModel?.load()
        }
    }

    private var inlineInputBar: some View {
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
}
