import SwiftUI
import AtmoCore

struct ConversationDetailView: View {
    let conversation: ConversationItem
    @Environment(ATProtoService.self) private var service
    @State private var viewModel: ConversationDetailViewModel?
    @State private var messageText: String = ""
    @FocusState private var isInputFocused: Bool
    /// The "+" attachment menu (iOS), springing up from the plus button.
    @State private var showAttachmentMenu = false
    @State private var showGIFPicker = false
    @State private var showBookmarkPicker = false

    var otherParticipant: ConversationItem.ParticipantInfo? {
        conversation.participants.first { $0.did != service.currentUserDID }
    }

    /// iPhone: the app's bottom bar hides while a conversation is open so
    /// this view's own composer owns the bottom edge.
    private var hidesAppBar: Bool {
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

        }
        // View-LOCAL inset: this is what actually keeps the message list
        // above the composer on a pushed screen — an inset applied to the
        // outer navigation container didn't reach this scroll view, so
        // fresh messages rendered behind the bar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inlineInputBar
        }
#if os(iOS)
        // The "+" menu floats above the bar; a tap anywhere else closes it.
        .overlay(alignment: .bottomLeading) {
            if showAttachmentMenu {
                ZStack(alignment: .bottomLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closeAttachmentMenu() }
                    AttachmentMenuPanel(
                        items: attachmentItems,
                        onSelect: { closeAttachmentMenu() }
                    )
                    .padding(.leading, AtmoTheme.Spacing.md)
                    .padding(.bottom, 70)
                    .transition(.scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showAttachmentMenu)
        .sheet(isPresented: $showGIFPicker) {
            GIFPickerSheet { gif in
                // Chat carries the GIF as its link; bubbles play it inline.
                Task { await viewModel?.sendMessage(text: gif.embedURL.absoluteString) }
            }
        }
        .sheet(isPresented: $showBookmarkPicker) {
            BookmarkPickerSheet { bookmark in
                Task { await viewModel?.sendPost(uri: bookmark.uri, cid: bookmark.cid) }
            }
        }
        // iMessage header: avatar over the name, tapping through to the
        // profile. Replaces the plain title on iOS only.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let other = otherParticipant {
                    NavigationLink(value: other.did) {
                        VStack(spacing: 2) {
                            AvatarView(url: other.avatarURL, size: 30)
                            HStack(spacing: 2) {
                                Text(other.displayName ?? other.handle)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(other.displayName ?? other.handle), view profile")
                } else {
                    Text("Chat").font(.headline)
                }
            }
        }
        .onAppear {
            guard hidesAppBar else { return }
            PhoneChromeState.shared.conversationOpen = true
        }
        .onDisappear {
            guard hidesAppBar else { return }
            PhoneChromeState.shared.conversationOpen = false
        }
#else
        .navigationTitle(otherParticipant?.displayName ?? otherParticipant?.handle ?? "Chat")
#endif
        .task {
            if viewModel == nil {
                viewModel = ConversationDetailViewModel(
                    conversationID: conversation.convoID,
                    service: service
                )
            }
#if os(iOS)
            // Belt for the appear/disappear pair: the flag is also set here,
            // which runs reliably on push.
            if hidesAppBar {
                PhoneChromeState.shared.conversationOpen = true
            }
#endif
            await viewModel?.load()
        }
    }

#if os(iOS)
    /// iMessage layout: a "+" disc, then a capsule field with the send
    /// button inside its trailing end (only while there's something to send).
    private var inlineInputBar: some View {
        HStack(alignment: .bottom, spacing: AtmoTheme.Spacing.sm) {
            Button {
                Haptics.tap()
                showAttachmentMenu.toggle()
            } label: {
                // The glyph rotates into an X while the menu is open; the
                // rotation sits under the glass so the disc stays put
                // (transforms after glassEffect displace the glass layer).
                Image(systemName: "plus")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.primary)
                    .rotationEffect(.degrees(showAttachmentMenu ? 45 : 0))
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showAttachmentMenu)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showAttachmentMenu ? "Close attachments" : "Attachments")

            HStack(alignment: .bottom, spacing: AtmoTheme.Spacing.xs) {
                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .lineLimit(1...5)
                    .padding(.leading, AtmoTheme.Spacing.md)
                    .padding(.vertical, 9)
                    .onChange(of: isInputFocused) { _, focused in
                        if focused { closeAttachmentMenu() }
                    }

                if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(AtmoColors.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 5)
                    .padding(.bottom, 5)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Send")
                } else {
                    Color.clear.frame(width: 30, height: 30)
                        .padding(.trailing, 5)
                        .padding(.bottom, 5)
                }
            }
            .frame(minHeight: 40)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: canSend)
        }
        .padding(.horizontal, AtmoTheme.Spacing.lg)
        .padding(.vertical, AtmoTheme.Spacing.sm)
    }

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = messageText
        messageText = ""
        Task { await viewModel?.sendMessage(text: text) }
    }

    private func closeAttachmentMenu() {
        if showAttachmentMenu { showAttachmentMenu = false }
    }

    /// The menu lists what Bluesky chat can carry. Media rows are declared
    /// but gated on ChatCapabilities.supportsMedia, so they appear on
    /// their own once the chat lexicon accepts media embeds.
    private var attachmentItems: [AttachmentMenuItem] {
        var items: [AttachmentMenuItem] = []
        if ChatCapabilities.supportsMedia {
            items += [
                AttachmentMenuItem(id: "camera", title: "Camera", systemImage: "camera.fill", tint: .gray) {},
                AttachmentMenuItem(id: "photos", title: "Photos", systemImage: "photo.on.rectangle.angled", tint: .blue) {},
                AttachmentMenuItem(id: "video", title: "Video", systemImage: "video.fill", tint: .indigo) {},
                AttachmentMenuItem(id: "voice", title: "Voice Memo", systemImage: "waveform", tint: .red) {},
                AttachmentMenuItem(id: "drawing", title: "Drawing", systemImage: "pencil.and.outline", tint: .orange) {},
            ]
        }
        if ChatCapabilities.supportsGIFLinks {
            items.append(AttachmentMenuItem(id: "gif", title: "GIF", systemImage: "play.rectangle.fill", tint: .pink) {
                showGIFPicker = true
            })
        }
        if ChatCapabilities.supportsPostEmbeds {
            items.append(AttachmentMenuItem(id: "bookmark", title: "Bookmarked Post", systemImage: "bookmark.fill", tint: AtmoColors.accent) {
                showBookmarkPicker = true
            })
        }
        return items
    }
#else
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
#endif
}
