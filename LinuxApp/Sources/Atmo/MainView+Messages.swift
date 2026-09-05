import Adwaita
import Foundation
import AtmoCore

extension MainView {

    struct ConversationRowSnapshot: Identifiable, Equatable {
        let id: String
        let title: String
        let avatarURL: URL?
        let lastMessage: String
        let time: String
        let unread: Int
    }

    struct MessageRowSnapshot: Identifiable, Equatable {
        let id: String
        let text: String
        let isMine: Bool
        let time: String?
        let embeddedPostURI: String?
    }

    struct CandidateRowSnapshot: Identifiable, Equatable {
        let id: String
        let name: String
        let handle: String
        let avatarURL: URL?
        let isMutual: Bool
    }

    // MARK: - Snapshots

    /// Everyone in the conversation but the signed-in user.
    func conversationTitle(_ conversation: ConversationItem) -> String {
        let me = onMain { AppSession.shared.service.currentUserDID }
        let others = conversation.participants.filter { $0.did != me }
        let names = others.map { $0.displayName ?? "@\($0.handle)" }
        return names.isEmpty ? "Conversation" : names.joined(separator: ", ")
    }

    var conversationRows: [ConversationRowSnapshot] {
        _ = tick
        return onMain {
            let me = AppSession.shared.service.currentUserDID
            return (AppSession.shared.dms?.conversations ?? []).map { convo in
                let others = convo.participants.filter { $0.did != me }
                return ConversationRowSnapshot(
                    id: convo.convoID,
                    title: conversationTitle(convo),
                    avatarURL: others.first?.avatarURL,
                    lastMessage: convo.lastMessage ?? "",
                    time: convo.lastMessageAt?.atmoFormatted() ?? "",
                    unread: convo.unreadCount
                )
            }
        }
    }

    var conversationsLoading: Bool {
        _ = tick
        return onMain { AppSession.shared.dms?.isLoading ?? false }
    }

    func messageRows(convoID: String) -> [MessageRowSnapshot] {
        _ = tick
        return onMain {
            let model = AppSession.shared.conversation(for: convoID)
            let me = AppSession.shared.service.currentUserDID
            return model.messages.enumerated().map { index, message in
                MessageRowSnapshot(
                    id: message.messageID,
                    text: message.text,
                    isMine: message.senderDID == me,
                    time: model.showsTimestamp(at: index) ? message.sentAt.atmoFormatted() : nil,
                    embeddedPostURI: message.embeddedPostURI
                )
            }
        }
    }

    func conversationState(convoID: String) -> (loading: Bool, sending: Bool) {
        _ = tick
        return onMain {
            let model = AppSession.shared.conversation(for: convoID)
            return (model.isLoading, model.isSending)
        }
    }

    // MARK: - Conversation list pane

    @ViewBuilder var messagesPane: Body {
        let rows = conversationRows
        if rows.isEmpty {
            if conversationsLoading {
                Spinner()
                    .vexpand()
                    .valign(.center)
            } else {
                StatusPage(
                    "No messages",
                    icon: .custom(name: "chat-message-new-symbolic"),
                    description: "Your direct messages will appear here."
                ) {
                    Button("New Message") { openNewMessage() }
                        .pill()
                        .style("suggested-action")
                        .halign(.center)
                }
                .vexpand()
            }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows, id: \.id) { row in
                        conversationRow(row)
                        Separator()
                    }
                }
                .frame(maxWidth: 720)
            }
            .vexpand()
        }
    }

    @ViewBuilder func conversationRow(_ row: ConversationRowSnapshot) -> Body {
        HStack(spacing: 10) {
            remoteAvatar(url: row.avatarURL, name: row.title, size: 44)
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .ellipsize()
                        .style("heading")
                        .halign(.start)
                        .hexpand()
                    Text(row.time)
                        .style("dim-label")
                        .style("caption")
                }
                Text(row.lastMessage.isEmpty ? "No messages yet" : row.lastMessage)
                    .ellipsize()
                    .style("dim-label")
                    .halign(.start)
            }
            .hexpand()
            if row.unread > 0 {
                Text("\(row.unread)")
                    .style("caption")
                    .style("accent")
                    .style("heading")
            }
        }
        .padding(10)
        .onClick {
            if let convo = onMain({ AppSession.shared.dms?.conversations.first { $0.convoID == row.id } }) {
                openConversation(convo)
            }
        }
    }

    // MARK: - Conversation page

    @ViewBuilder func conversationPage(convoID: String) -> Body {
        let rows = messageRows(convoID: convoID)
        let state = conversationState(convoID: convoID)
        VStack(spacing: 0) {
            if rows.isEmpty && state.loading {
                Spinner()
                    .vexpand()
                    .valign(.center)
            } else if rows.isEmpty {
                StatusPage("Say hello", icon: .custom(name: "chat-message-new-symbolic"), description: "No messages yet.")
                    .vexpand()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(rows, id: \.id) { row in
                            messageBubble(row)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: 720)
                }
                .vexpand()
            }
            HStack(spacing: 8) {
                Entry("Message…", text: $messageText)
                    .activate { sendMessage(convoID: convoID) }
                    .hexpand()
                Button(icon: .custom(name: "mail-send-symbolic")) { sendMessage(convoID: convoID) }
                    .style("suggested-action")
                    .tooltip("Send")
                    .insensitive(messageText.trimmingCharacters(in: .whitespaces).isEmpty || state.sending)
            }
            .padding(10)
        }
    }

    @ViewBuilder func messageBubble(_ row: MessageRowSnapshot) -> Body {
        VStack(spacing: 2) {
            if let time = row.time {
                Text(time)
                    .style("caption")
                    .style("dim-label")
                    .halign(.center)
                    .padding(6, .vertical)
            }
            VStack(spacing: 4) {
                if !row.text.isEmpty {
                    Text(row.text)
                        .wrap()
                        .xalign(0)
                        .selectable()
                }
                if let uri = row.embeddedPostURI {
                    Button("View shared post", icon: .custom(name: "atmo-thread-symbolic")) { openThread(uri: uri) }
                        .flat()
                }
            }
            .padding(10)
            .style("card")
            .style("accent", active: row.isMine)
            .halign(row.isMine ? .end : .start)
            .frame(maxWidth: 480)
        }
    }

    func sendMessage(convoID: String) {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        runCore {
            let model = AppSession.shared.conversation(for: convoID)
            await model.sendMessage(text: text)
            if model.error != nil {
                messageText = text
                presentError("The message couldn't be sent.")
            }
            await AppSession.shared.dms?.load()
        }
    }

    // MARK: - New message dialog

    var candidateRows: [CandidateRowSnapshot] {
        _ = tick
        return onMain {
            guard let model = AppSession.shared.newConversation else { return [] }
            let source = newMessageQuery.trimmingCharacters(in: .whitespaces).isEmpty ? model.suggestions : model.searchResults
            return source.map {
                CandidateRowSnapshot(id: $0.did, name: $0.displayName ?? $0.handle, handle: $0.handle, avatarURL: $0.avatarURL, isMutual: $0.isMutual)
            }
        }
    }

    func openNewMessage() {
        newMessageQuery = ""
        newMessageVisible = true
        runCore { await AppSession.shared.newConversation?.loadSuggestions() }
    }

    @ViewBuilder var newMessageContent: Body {
        let rows = candidateRows
        VStack(spacing: 0) {
            SearchEntry()
                .placeholderText("Search people")
                .text($newMessageQuery)
                .padding(10)
            let _ = onMain { AppSession.shared.newConversation?.onQueryChanged(newMessageQuery) }
            if rows.isEmpty {
                StatusPage("No one found", icon: .custom(name: "system-users-symbolic"), description: "People who follow you back appear here first.")
                    .vexpand()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.id) { person in
                            candidateRow(person) {
                                startConversation(did: person.id)
                            }
                            Separator()
                        }
                    }
                }
                .vexpand()
            }
        }
    }

    @ViewBuilder func candidateRow(_ person: CandidateRowSnapshot, trailing: String? = nil, action: @escaping () -> Void) -> Body {
        HStack(spacing: 10) {
            remoteAvatar(url: person.avatarURL, name: person.name, size: 36)
            VStack(spacing: 0) {
                Text(person.name)
                    .ellipsize()
                    .style("heading")
                    .halign(.start)
                Text("@\(person.handle)" + (person.isMutual ? " · follows you" : ""))
                    .ellipsize()
                    .style("dim-label")
                    .style("caption")
                    .halign(.start)
            }
            .hexpand()
            if let trailing {
                Text(trailing)
                    .style("caption")
                    .style("dim-label")
            }
        }
        .padding(10)
        .onClick(handler: action)
    }

    func startConversation(did: String) {
        newMessageVisible = false
        runCore {
            guard let convo = await AppSession.shared.newConversation?.openConversation(with: did) else {
                presentError("A conversation couldn't be opened with that account.")
                return
            }
            selectSidebar(PaneID.messages)
            openConversation(convo)
        }
    }

    // MARK: - Send post dialog

    var sendPostVisibleBinding: Binding<Bool> {
        Binding(
            get: { sendPostVisible },
            set: { visible in
                sendPostVisible = visible
                if !visible { onMain { AppSession.shared.sendPost = nil } }
            }
        )
    }

    func openSendPost(uri: String, actions: RowActions) {
        guard let post = onMain({ post(uri: uri, actions: actions) }) else { return }
        onMain { AppSession.shared.sendPost = SendPostViewModel(post: post, service: AppSession.shared.service) }
        sendPostQuery = ""
        sendPostVisible = true
        runCore { await AppSession.shared.sendPost?.load() }
    }

    struct SendTargetSnapshot: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let avatarURL: URL?
        let state: String
        let isConversation: Bool
    }

    var sendTargets: [SendTargetSnapshot] {
        _ = tick
        return onMain {
            guard let model = AppSession.shared.sendPost else { return [] }
            func label(_ state: SendPostViewModel.SendState) -> String {
                switch state {
                case .idle: return "Send"
                case .sending: return "Sending…"
                case .sent: return "Sent"
                case .failed: return "Retry"
                }
            }
            let me = AppSession.shared.service.currentUserDID
            var rows: [SendTargetSnapshot] = []
            let query = sendPostQuery.trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                for convo in model.conversations {
                    let others = convo.participants.filter { $0.did != me }
                    rows.append(SendTargetSnapshot(
                        id: convo.convoID,
                        title: others.map { $0.displayName ?? "@\($0.handle)" }.joined(separator: ", "),
                        subtitle: "Conversation",
                        avatarURL: others.first?.avatarURL,
                        state: label(model.state(for: convo.convoID)),
                        isConversation: true
                    ))
                }
            }
            let people = query.isEmpty ? model.people.suggestions : model.people.searchResults
            for person in people where !rows.contains(where: { $0.id == person.did }) {
                rows.append(SendTargetSnapshot(
                    id: person.did,
                    title: person.displayName ?? person.handle,
                    subtitle: "@\(person.handle)",
                    avatarURL: person.avatarURL,
                    state: label(model.state(for: person.did)),
                    isConversation: false
                ))
            }
            return rows
        }
    }

    @ViewBuilder var sendPostContent: Body {
        let rows = sendTargets
        VStack(spacing: 0) {
            SearchEntry()
                .placeholderText("Search people")
                .text($sendPostQuery)
                .padding(10)
            let _ = onMain { AppSession.shared.sendPost?.onQueryChanged(sendPostQuery) }
            if rows.isEmpty {
                StatusPage("No recipients", icon: .custom(name: "mail-send-symbolic"), description: "Recent conversations and people you follow appear here.")
                    .vexpand()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.id) { target in
                            HStack(spacing: 10) {
                                remoteAvatar(url: target.avatarURL, name: target.title, size: 36)
                                VStack(spacing: 0) {
                                    Text(target.title)
                                        .ellipsize()
                                        .style("heading")
                                        .halign(.start)
                                    Text(target.subtitle)
                                        .ellipsize()
                                        .style("dim-label")
                                        .style("caption")
                                        .halign(.start)
                                }
                                .hexpand()
                                Button(target.state) { sendPost(to: target) }
                                    .pill()
                                    .style("suggested-action", active: target.state == "Send")
                                    .insensitive(target.state == "Sending…" || target.state == "Sent")
                            }
                            .padding(10)
                            Separator()
                        }
                    }
                }
                .vexpand()
            }
        }
    }

    func sendPost(to target: SendTargetSnapshot) {
        runCore {
            guard let model = AppSession.shared.sendPost else { return }
            if target.isConversation, let convo = model.conversations.first(where: { $0.convoID == target.id }) {
                await model.send(toConversation: convo)
            } else {
                await model.send(toPerson: target.id)
            }
        }
    }
}
