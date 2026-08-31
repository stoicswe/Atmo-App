import SwiftUI
import AtmoCore

// MARK: - GIF Picker
/// Search-and-pick sheet backed by Bluesky's GIF proxy (the same selection
/// the official app offers). While Bluesky migrates the proxy off the
/// discontinued Tenor API, the picker shows an unavailable notice — no
/// code changes needed once the proxy is back.
struct GIFPickerSheet: View {
    let onPick: (GIFItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var items: [GIFItem] = []
    @State private var isLoading = false
    @State private var unavailable = false
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            Group {
                if unavailable {
                    ContentUnavailableView(
                        "GIF Search Is Unavailable",
                        systemImage: "photo.stack",
                        description: Text("Bluesky is switching GIF providers after Tenor's shutdown. This will start working again automatically.")
                    )
                } else if isLoading && items.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    grid
                }
            }
            .navigationTitle("GIFs")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .searchable(text: $query, prompt: "Search GIFs")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await load { try await GIFService.featured() } }
            .onChange(of: query) { _, term in
                searchTask?.cancel()
                searchTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    if term.trimmingCharacters(in: .whitespaces).isEmpty {
                        await load { try await GIFService.featured() }
                    } else {
                        await load { try await GIFService.search(term) }
                    }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 460, minHeight: 540)
#endif
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(items) { item in
                    Button {
                        Haptics.tap()
                        onPick(item)
                        dismiss()
                    } label: {
                        Color.clear
                            .aspectRatio(4.0 / 3.0, contentMode: .fit)
                            .overlay {
                                AsyncCachedImage(url: item.previewURL) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Color.secondary.opacity(0.15)
                                    }
                                }
                            }
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.small, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                }
            }
            .padding(AtmoTheme.Spacing.md)
        }
    }

    private func load(_ fetch: @escaping () async throws -> [GIFItem]) async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await fetch()
            unavailable = false
        } catch {
            unavailable = true
        }
    }
}
