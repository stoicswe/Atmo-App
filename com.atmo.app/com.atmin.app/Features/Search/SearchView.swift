import SwiftUI

// MARK: - SearchView
//
// Accepts a pre-created, persistent SearchViewModel from AppNavigation so that
// search state (query, results) survives sidebar/tab switches just like the timeline.
// The VM's own 5-minute auto-clear fires when the user navigates away long enough.

struct SearchView: View {
    @Bindable var viewModel: SearchViewModel

    /// When non-nil (iPad/macOS split view), navigation uses the shared parent
    /// NavigationStack in AppNavigation. When nil (iPhone), owns its own stack.
    var splitNavPath: Binding<NavigationPath>? = nil
    @State private var ownedNavPath = NavigationPath()

    private var navPath: Binding<NavigationPath> {
        splitNavPath ?? $ownedNavPath
    }

    var body: some View {
        if splitNavPath != nil {
            searchContent(vm: viewModel)
        } else {
            NavigationStack(path: $ownedNavPath) {
                searchContent(vm: viewModel)
                    .navigationTitle("Search")
#if os(iOS)
                    .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
#endif
                    .navigationDestination(for: PostNavTarget.self) { target in
                        ThreadView(postURI: target.uri)
                    }
                    .navigationDestination(for: String.self) { did in
                        ProfileView(actorDID: did)
                    }
            }
        }
    }

    // MARK: - Main search content

    @ViewBuilder
    private func searchContent(vm: SearchViewModel) -> some View {
        // resultBody fills all remaining vertical space; the search bar + chips
        // are pinned to the top via safeAreaInset so they're always visible.
        //
        // IMPORTANT: the search bar is wired via a pure string binding here.
        // onQueryChanged is fired through .onChange(of:) on the TextField inside
        // SearchBar — NOT in the binding setter. This means typing never causes
        // a view-tree rebuild that would dismiss the keyboard or reset focus.
        resultBody(vm: vm)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    // ── Search bar ──
                    SearchBar(query: $viewModel.query) { newValue in
                        vm.onQueryChanged(newValue)
                    }
                    .padding(.horizontal, AtmoTheme.Spacing.md)
                    .padding(.top, AtmoTheme.Spacing.sm)
                    .padding(.bottom, AtmoTheme.Spacing.xs)

                    // ── Category picker ──
                    categoryPicker(vm: vm)
                        .padding(.horizontal, AtmoTheme.Spacing.md)
                        .padding(.bottom, AtmoTheme.Spacing.sm)

                    Divider().overlay(AtmoColors.glassDivider)
                }
                .background(.bar)
            }
            .onAppear  { vm.onAppear()  }
            .onDisappear { vm.onDisappear() }
    }

    // MARK: - Category Picker

    @ViewBuilder
    private func categoryPicker(vm: SearchViewModel) -> some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            ForEach(SearchCategory.allCases) { category in
                CategoryChip(
                    category: category,
                    isSelected: vm.selectedCategory == category,
                    count: resultCount(for: category, vm: vm)
                ) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        vm.selectedCategory = category
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func resultCount(for category: SearchCategory, vm: SearchViewModel) -> Int? {
        guard !vm.postResults.isEmpty || !vm.peopleResults.isEmpty || !vm.hashtagResults.isEmpty
        else { return nil }
        switch category {
        case .posts:    return vm.postResults.count
        case .people:   return vm.peopleResults.count
        case .hashtags: return vm.hashtagResults.count
        }
    }

    // MARK: - Result Body

    @ViewBuilder
    private func resultBody(vm: SearchViewModel) -> some View {
        // The view tree structure never changes based on isLoading — doing so
        // would rebuild the safeAreaInset that holds the search bar, which
        // dismisses the keyboard. Instead, overlay a spinner on top of the
        // existing (possibly stale) results while a new search is in-flight.
        ZStack {
            if vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyPrompt
            } else {
                switch vm.selectedCategory {
                case .posts:
                    postsResults(vm: vm)
                case .people:
                    peopleResults(vm: vm)
                case .hashtags:
                    hashtagResults(vm: vm)
                }
            }

            // Spinner floats above content while loading; the underlying
            // results (or empty state) stay mounted so no view rebuild occurs.
            if vm.isLoading {
                ProgressView()
                    .tint(AtmoColors.skyBlue)
                    .padding(AtmoTheme.Spacing.lg)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Empty prompt (no query entered yet)

    private var emptyPrompt: some View {
        ContentUnavailableView(
            "Search Bluesky",
            systemImage: "magnifyingglass",
            description: Text("Find posts, people, and hashtags.")
        )
    }

    // MARK: - Posts Results

    @ViewBuilder
    private func postsResults(vm: SearchViewModel) -> some View {
        if vm.postResults.isEmpty {
            noResults(icon: "text.bubble", message: "No posts found for \"\(vm.query)\"")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.postResults) { post in
                        SearchPostRow(post: post)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                navPath.wrappedValue = NavigationPath([PostNavTarget(uri: post.uri)])
                            }
                        Divider().overlay(Color.secondary.opacity(0.1))
                    }
                }
            }
        }
    }

    // MARK: - People Results

    @ViewBuilder
    private func peopleResults(vm: SearchViewModel) -> some View {
        if vm.peopleResults.isEmpty {
            noResults(icon: "person.2", message: "No accounts found for \"\(vm.query)\"")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.peopleResults) { person in
                        SearchPersonRow(person: person)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                navPath.wrappedValue = NavigationPath([person.did])
                            }
                        Divider().overlay(Color.secondary.opacity(0.1))
                    }
                }
            }
        }
    }

    // MARK: - Hashtag Results

    @ViewBuilder
    private func hashtagResults(vm: SearchViewModel) -> some View {
        if vm.hashtagResults.isEmpty {
            noResults(
                icon: "number",
                message: vm.query.contains("#")
                    ? "No hashtags in your query"
                    : "Type #hashtag to search for tags"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.hashtagResults, id: \.self) { tag in
                        HashtagRow(tag: tag)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Re-run search scoped to this hashtag
                                let newQuery = "#\(tag)"
                                vm.query = newQuery
                                vm.onQueryChanged(newQuery)
                                vm.selectedCategory = .posts
                            }
                        Divider().overlay(Color.secondary.opacity(0.1))
                    }
                }
            }
        }
    }

    // MARK: - No Results placeholder

    private func noResults(icon: String, message: String) -> some View {
        ContentUnavailableView(
            "No Results",
            systemImage: icon,
            description: Text(message)
        )
    }
}

// MARK: - Search Bar
//
// `query` is a pure two-way string binding — no side effects in the setter.
// `onCommit` is called via .onChange(of:) so search triggering is decoupled
// from SwiftUI's binding update cycle and never causes a view-tree rebuild
// that would dismiss the keyboard or reset focus.

private struct SearchBar: View {
    @Binding var query: String
    /// Called after every debounce-eligible keystroke with the new value.
    var onCommit: ((String) -> Void)? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.subheadline)

            TextField("Search Bluesky…", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                // Fire the search callback on every change — the ViewModel
                // handles debouncing and minimum-length gating internally.
                .onChange(of: query) { _, newValue in
                    onCommit?(newValue)
                }

            if !query.isEmpty {
                Button {
                    query = ""
                    // Notify the VM so it can clear results immediately
                    onCommit?("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, AtmoTheme.Spacing.md)
        .padding(.vertical, AtmoTheme.Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: query.isEmpty)
    }
}

// MARK: - Category Chip

private struct CategoryChip: View {
    let category: SearchCategory
    let isSelected: Bool
    let count: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: category.icon)
                    .font(.caption.weight(.medium))
                Text(category.rawValue)
                    .font(.caption.weight(.semibold))
                if let count = count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : AtmoColors.skyBlue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background {
                            Capsule()
                                .fill(isSelected
                                      ? Color.white.opacity(0.25)
                                      : AtmoColors.skyBlue.opacity(0.15))
                        }
                }
            }
            .foregroundStyle(isSelected ? .white : .secondary)
            .padding(.horizontal, AtmoTheme.Spacing.md)
            .padding(.vertical, AtmoTheme.Spacing.xs)
            .background {
                Capsule()
                    .fill(isSelected ? AtmoColors.skyBlue : Color.secondary.opacity(0.1))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search Post Row

/// Compact post cell used in search results — no thread context or action row,
/// just enough to identify the post and let the user tap into it.
private struct SearchPostRow: View {
    let post: PostItem

    var body: some View {
        HStack(alignment: .top, spacing: AtmoTheme.Feed.avatarTextSpacing) {
            AvatarView(url: post.authorAvatarURL, size: AtmoTheme.Feed.avatarSize)

            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.xs) {
                // Author line
                HStack(spacing: AtmoTheme.Spacing.xs) {
                    if let name = post.authorDisplayName {
                        Text(name)
                            .font(AtmoFonts.authorName)
                            .lineLimit(1)
                    }
                    Text("@\(post.authorHandle)")
                        .font(AtmoFonts.authorHandle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(post.indexedAt.atmoFormatted())
                        .font(AtmoFonts.timestamp)
                        .foregroundStyle(.tertiary)
                }

                // Post text
                if !post.text.isEmpty {
                    Text(post.text)
                        .font(.subheadline)
                        .lineLimit(3)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Feed.verticalPadding)
    }
}

// MARK: - Search Person Row

private struct SearchPersonRow: View {
    let person: ProfileModel

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.md) {
            AvatarView(url: person.avatarURL, size: AtmoTheme.AvatarSize.medium)

            VStack(alignment: .leading, spacing: 2) {
                if let name = person.displayName {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Text("@\(person.handle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let bio = person.description, !bio.isEmpty {
                    Text(bio)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.sm)
    }
}

// MARK: - Hashtag Row

private struct HashtagRow: View {
    let tag: String

    var body: some View {
        HStack(spacing: AtmoTheme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(AtmoColors.skyBlue.opacity(0.12))
                    .frame(width: 36, height: 36)
                Text("#")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(AtmoColors.skyBlue)
            }

            Text("#\(tag)")
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
        .padding(.vertical, AtmoTheme.Spacing.sm)
    }
}
