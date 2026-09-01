import SwiftUI
import AtmoCore

// MARK: - Send Post Sheet
// "Send post in a message": the post at the top, then recent
// conversations and people (mutuals, follows, search) — each row with its
// own Send button that turns into a spinner and then "Sent", so one post
// can go to several people without leaving the sheet. The post arrives
// as a tappable card in the conversation (see MessageBubbleView).
struct SendPostSheet: View {
    let post: PostItem

    @Environment(ATProtoService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SendPostViewModel?
    @State private var searchText: String = ""
    /// Candidate awaiting the ask-a-parent flow (managed child accounts).
    @State private var askTarget: NewConversationViewModel.Candidate? = nil

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    recipientList(vm: vm)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Send Post")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $askTarget) { candidate in
                AskToDMSheet(handle: candidate.handle, displayName: candidate.displayName)
                    .themedBackdrop()
            }
            .themedBackdrop()
        }
#if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 520, idealHeight: 600)
#endif
        .task {
            if viewModel == nil {
                viewModel = SendPostViewModel(post: post, service: service)
            }
            await viewModel?.load()
        }
    }

    // MARK: List

    @ViewBuilder
    private func recipientList(vm: SendPostViewModel) -> some View {
        List {
            Section {
                postPreview
            }

            if searchText.isEmpty {
                let recent = vm.conversations
                let mutuals = vm.people.suggestions.filter(\.isMutual)
                let others = vm.people.suggestions.filter { !$0.isMutual }

                if (vm.isLoadingConversations || vm.people.isLoading),
                   recent.isEmpty, vm.people.suggestions.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent) { conversationRow($0, vm: vm) }
                    }
                }
                if !mutuals.isEmpty {
                    Section("Mutuals") {
                        ForEach(mutuals) { personRow($0, vm: vm) }
                    }
                }
                if !others.isEmpty {
                    Section("Following") {
                        ForEach(others) { personRow($0, vm: vm) }
                    }
                }
            } else {
                ForEach(vm.people.searchResults) { personRow($0, vm: vm) }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search people…")
        .onChange(of: searchText) { _, newValue in
            vm.onQueryChanged(newValue)
        }
        .overlay {
            if !searchText.isEmpty && vm.people.searchResults.isEmpty {
                ContentUnavailableView(
                    "No one found",
                    systemImage: "person.slash",
                    description: Text("Only people whose message settings allow you to reach them are shown.")
                )
            }
        }
    }

    // MARK: Post preview

    private var postPreview: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Spacing.sm) {
            AvatarView(url: post.authorAvatarURL, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    Text(post.authorDisplayName ?? "@\(post.authorHandle)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if post.authorDisplayName != nil {
                        Text("@\(post.authorHandle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(post.text.isEmpty ? "Post" : post.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, AtmoTheme.Spacing.xs)
    }

    // MARK: Rows

    private func conversationRow(_ conversation: ConversationItem, vm: SendPostViewModel) -> some View {
        let others = conversation.participants.filter { $0.did != vm.currentUserDID }
        let shown = others.isEmpty ? Array(conversation.participants.prefix(1)) : others
        return HStack(spacing: AtmoTheme.Spacing.md) {
            AvatarView(url: shown.first?.avatarURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.map { $0.displayName ?? $0.handle }.joined(separator: ", "))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if shown.count == 1, let handle = shown.first?.handle {
                    Text("@\(handle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: AtmoTheme.Spacing.sm)
            SendRowButton(state: vm.state(for: conversation.convoID)) {
                Haptics.tap()
                Task { await vm.send(toConversation: conversation) }
            }
        }
        .padding(.vertical, AtmoTheme.Spacing.xs)
    }

    private func personRow(_ candidate: NewConversationViewModel.Candidate, vm: SendPostViewModel) -> some View {
        HStack(spacing: AtmoTheme.Spacing.md) {
            AvatarView(url: candidate.avatarURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.displayName ?? candidate.handle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("@\(candidate.handle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: AtmoTheme.Spacing.sm)
            SendRowButton(state: vm.state(for: candidate.did)) {
                // Family controls: a managed child account asks a parent
                // before starting a NEW conversation.
                guard ParentalControlsStore.shared.canStartDM(with: candidate.handle) else {
                    askTarget = candidate
                    return
                }
                Haptics.tap()
                Task { await vm.send(toPerson: candidate.did) }
            }
        }
        .padding(.vertical, AtmoTheme.Spacing.xs)
    }
}

// MARK: - Send Row Button
/// Send → spinner → "Sent" (or "Retry" after a failure), sized like a
/// compact capsule so rows stay one line tall.
private struct SendRowButton: View {
    let state: SendPostViewModel.SendState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch state {
                case .idle:
                    Text("Send")
                case .sending:
                    ProgressView()
                        .controlSize(.small)
                case .sent:
                    Label("Sent", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                case .failed:
                    Text("Retry")
                }
            }
            .font(.caption.weight(.semibold))
            .frame(minWidth: 56)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(state == .sent ? AtmoColors.repostGreen : (state == .failed ? AtmoColors.likeRed : .white))
            .background(
                Capsule().fill(state == .sent || state == .failed ? Color.secondary.opacity(0.12) : AtmoColors.accent)
            )
        }
        .buttonStyle(.plain)
        .disabled(!SendPostViewModel.canStart(state))
        .animation(.easeInOut(duration: 0.15), value: state)
        .accessibilityLabel(state == .sent ? "Sent" : "Send post")
    }
}
