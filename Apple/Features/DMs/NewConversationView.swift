import SwiftUI
import AtmoCore

// MARK: - NewConversationView
// Recipient picker for a new DM: the user's mutual follows first, then
// everyone else they follow, plus a network search — all filtered by
// AtmoCore to accounts whose chat settings accept a message from this
// user. Tapping a person opens (or creates) the 1:1 conversation.
struct NewConversationView: View {
    /// Fired with the opened conversation; the presenter navigates to it.
    var onOpenConversation: ((ConversationItem) -> Void)? = nil

    @Environment(ATProtoService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: NewConversationViewModel?
    @State private var searchText: String = ""
    /// The candidate currently being opened (shows a row spinner).
    @State private var openingDID: String? = nil
    /// Candidate awaiting the ask-a-parent flow (managed child accounts).
    @State private var askTarget: NewConversationViewModel.Candidate? = nil

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    candidateList(vm: vm)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("New Message")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(item: $askTarget) { candidate in
                // AskToDMSheet lives in the platform layer (shared with the
                // watch target), which has no theme modifiers — the wash is
                // applied here at the presentation site instead.
                AskToDMSheet(handle: candidate.handle, displayName: candidate.displayName)
                    .themedBackdrop()
            }
            .themedBackdrop()
        }
        .task {
            if viewModel == nil {
                viewModel = NewConversationViewModel(service: service)
            }
            await viewModel?.loadSuggestions()
        }
    }

    @ViewBuilder
    private func candidateList(vm: NewConversationViewModel) -> some View {
        List {
            if searchText.isEmpty {
                let mutuals = vm.suggestions.filter(\.isMutual)
                let others = vm.suggestions.filter { !$0.isMutual }

                if vm.isLoading && vm.suggestions.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                if !mutuals.isEmpty {
                    Section("Mutuals") {
                        ForEach(mutuals) { candidateRow($0, vm: vm) }
                    }
                }
                if !others.isEmpty {
                    Section("Following") {
                        ForEach(others) { candidateRow($0, vm: vm) }
                    }
                }
            } else {
                ForEach(vm.searchResults) { candidateRow($0, vm: vm) }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search people…")
        .onChange(of: searchText) { _, newValue in
            vm.onQueryChanged(newValue)
        }
        .overlay {
            if !searchText.isEmpty && vm.searchResults.isEmpty {
                ContentUnavailableView(
                    "No one found",
                    systemImage: "person.slash",
                    description: Text("Only people whose message settings allow you to reach them are shown.")
                )
            }
        }
    }

    @ViewBuilder
    private func candidateRow(
        _ candidate: NewConversationViewModel.Candidate,
        vm: NewConversationViewModel
    ) -> some View {
        Button {
            guard openingDID == nil else { return }
            // Family controls: a managed child account asks a parent
            // before starting a NEW conversation. Approved handles (and
            // non-managed accounts) go straight through.
            guard ParentalControlsStore.shared.canStartDM(with: candidate.handle) else {
                askTarget = candidate
                return
            }
            openingDID = candidate.did
            Task {
                if let convo = await vm.openConversation(with: candidate.did) {
                    onOpenConversation?(convo)
                    dismiss()
                }
                openingDID = nil
            }
        } label: {
            HStack(spacing: AtmoTheme.Spacing.md) {
                AvatarView(url: candidate.avatarURL, size: AtmoTheme.AvatarSize.small)
                VStack(alignment: .leading, spacing: 2) {
                    if let name = candidate.displayName {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                    }
                    Text("@\(candidate.handle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if openingDID == candidate.did {
                    ProgressView()
                } else if candidate.isMutual {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
}
