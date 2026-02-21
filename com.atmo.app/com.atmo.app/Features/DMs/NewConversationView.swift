import SwiftUI
import ATProtoKit

struct NewConversationView: View {
    @Environment(ATProtoService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""
    @State private var searchResults: [AppBskyLexicon.Actor.ProfileViewDefinition] = []
    @State private var isSearching: Bool = false
    @State private var selectedDID: String? = nil

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    ProgressView()
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(searchResults, id: \.actorDID) { profile in
                        Button {
                            selectedDID = profile.actorDID
                        } label: {
                            HStack {
                                AvatarView(url: profile.avatarImageURL, size: AtmoTheme.AvatarSize.small)
                                VStack(alignment: .leading, spacing: 2) {
                                    if let name = profile.displayName {
                                        Text(name).font(.subheadline.weight(.semibold))
                                    }
                                    Text("@\(profile.actorHandle)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search people…")
            .onChange(of: searchText) { _, query in
                guard !query.isEmpty else {
                    searchResults = []
                    return
                }
                Task { await search(query: query) }
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
        }
    }

    private func search(query: String) async {
        guard let kit = service.atProtoKit else { return }
        isSearching = true
        do {
            let output = try await kit.searchActors(matching: query, limit: 20)
            searchResults = output.actors
        } catch {}
        isSearching = false
    }
}
