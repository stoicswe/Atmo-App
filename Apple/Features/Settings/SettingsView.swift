import SwiftUI
import AtmoCore
import StoreKit
import Combine

// MARK: - Settings
// Multi-tab settings, mirroring the {m.txt} editor's preferences window:
// Appearance (auto/light/dark + the shared accent palette), Accessibility,
// Account (session + sign out), and About (developer profile + tip jar).
// macOS gets a native preferences TabView; iOS switches sections with a
// Mail-style category chip bar — the selected section is an expanded
// accent capsule with icon + label, the rest collapse to icon circles.
struct SettingsView: View {

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case notifications = "Notifications"
        case family = "Family"
        case accessibility = "Accessibility"
        case account = "Account"
        case about = "About"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .appearance:    return "paintbrush"
            case .notifications: return "bell.badge"
            case .family:        return "figure.2.and.child.holdinghands"
            case .accessibility: return "figure.arms.open"
            case .account:       return "person.crop.circle"
            case .about:         return "info.circle"
            }
        }
    }

    @State private var selectedTab: SettingsTab = .appearance

    var body: some View {
#if os(macOS)
        TabView {
            AppearanceTab()
                .tabItem { Label(SettingsTab.appearance.rawValue, systemImage: SettingsTab.appearance.icon) }
            NotificationsSettingsTab()
                .tabItem { Label(SettingsTab.notifications.rawValue, systemImage: SettingsTab.notifications.icon) }
            FamilyTab()
                .tabItem { Label(SettingsTab.family.rawValue, systemImage: SettingsTab.family.icon) }
            AccessibilityTab()
                .tabItem { Label(SettingsTab.accessibility.rawValue, systemImage: SettingsTab.accessibility.icon) }
            AccountTab()
                .tabItem { Label(SettingsTab.account.rawValue, systemImage: SettingsTab.account.icon) }
            AboutTab()
                .tabItem { Label(SettingsTab.about.rawValue, systemImage: SettingsTab.about.icon) }
        }
        .navigationTitle("Settings")
#else
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AtmoTheme.Spacing.sm) {
                    ForEach(SettingsTab.allCases) { tab in
                        CategoryChip(tab: tab, isSelected: selectedTab == tab) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selectedTab = tab
                            }
                        }
                    }
                }
                .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
                .padding(.vertical, AtmoTheme.Spacing.sm)
            }

            switch selectedTab {
            case .appearance:    AppearanceTab()
            case .notifications: NotificationsSettingsTab()
            case .family:        FamilyTab()
            case .accessibility: AccessibilityTab()
            case .account:       AccountTab()
            case .about:         AboutTab()
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

#if os(iOS)
    // Mail-style category chip: a compact icon circle that expands into a
    // tinted capsule with its label when selected.
    private struct CategoryChip: View {
        let tab: SettingsTab
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 15, weight: .medium))
                    if isSelected {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize()
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .padding(.horizontal, isSelected ? AtmoTheme.Spacing.lg : 0)
                .frame(height: 40)
                .frame(minWidth: 40)
                .background {
                    Capsule().fill(isSelected ? AtmoColors.accent : Color.secondary.opacity(0.12))
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
#endif
}

// MARK: - Family
// Content controls in one place: the sensitive-media policy and the
// Apple Family (Declared Age Range / PermissionKit) managed controls.

private struct FamilyTab: View {
    @AppStorage(SensitiveMediaPolicy.storageKey) private var sensitivePolicyRaw: String = SensitiveMediaPolicy.defaultPolicy.rawValue
    @AppStorage(FamilyControlsIntegration.probedKey) private var hasProbedAgeRange: Bool = false

    var body: some View {
        Form {
            sensitiveContentSection
            familySection
            disclaimerSection
        }
#if os(macOS)
        .formStyle(.grouped)
#endif
    }

    // MARK: Disclaimer

    private var disclaimerSection: some View {
        Section {
            Link(destination: URL(string: "https://www.apple.com/families/")!) {
                Label("Learn about Apple parental controls", systemImage: "arrow.up.right")
            }
        } footer: {
            Text("@omic supports Apple's parental controls for child accounts, including the age range a parent shares through Family Sharing and ask-a-parent permission requests. These protections are provided by Apple's family frameworks — what can be managed here, and how approvals work, is determined by that SDK and your device's Family settings, not by @omic itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Sensitive content

    private var sensitiveContentSection: some View {
        Section {
            Picker("Explicit images", selection: $sensitivePolicyRaw) {
                ForEach(SensitiveMediaPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(ParentalControlsStore.shared.active.locksSensitiveMediaHidden)
        } header: {
            Text("Sensitive Content")
        } footer: {
            Text(ParentalControlsStore.shared.active.locksSensitiveMediaHidden
                 ? "Locked to Hide by your Family settings."
                 : "Applies to media labeled adult or graphic on Bluesky. Blur covers it until you tap Show; Hide removes it entirely. When your device's Sensitive Content Warning (Settings → Privacy & Security) is on, unlabeled nudity is also detected on-device — the same protection iMessage uses; nothing leaves your device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Managed controls
    // Read-only reflection of the managed state: a child can see what's in
    // force but only parent-approval flows can change it.

    private var familySection: some View {
        let store = ParentalControlsStore.shared
        return Section {
            LabeledContent("Account", value: familyStatusText(store.ageCategory))
            if store.isChildAccount {
                Group {
                    Toggle("Ask before new chats", isOn: .constant(store.active.requiresAskToDM))
                    Toggle("Show my posts in Discover", isOn: .constant(store.active.showsPostsInDiscover))
                    Toggle("New message alerts", isOn: .constant(store.active.allowsDMNotifications))
                    Toggle("Open links in browser", isOn: .constant(store.active.allowsLinkBrowsing))
                }
                .disabled(true)
                LabeledContent("Sensitive media", value: "Hidden")
            }
            Button("Check Family Settings") {
                // Clearing the flag re-arms the root probe, which watches
                // this value and re-runs immediately.
                hasProbedAgeRange = false
            }
        } header: {
            Text("Managed Controls")
        } footer: {
            Text(store.isChildAccount
                 ? "These controls are managed through Apple Family settings and parent approvals — they can't be changed here."
                 : "When a parent shares an age range for this device's account (Settings → Family), managed controls apply automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func familyStatusText(_ category: AgeCategory) -> String {
        switch category {
        case .unknown: return "Not managed"
        case .child: return "Child (managed)"
        case .teen: return "Teen"
        case .adult: return "Adult"
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @AppStorage(ThemeKeys.colorScheme) private var schemeRaw: String = AppearanceOption.system.rawValue
    @AppStorage(ThemeKeys.accentPresetID) private var accentID: String = AccentPresets.defaultID
    @AppStorage(FeedPreferences.infiniteScrollKey) private var infiniteScrollEnabled: Bool = true
#if os(iOS)
    @AppStorage(PhoneBarConfig.labelsKey) private var phoneBarShowsLabels: Bool = false
#endif

    var body: some View {
        Form {
            Section {
                Toggle("Infinite scroll", isOn: $infiniteScrollEnabled)
            } header: {
                Text("Feed")
            } footer: {
                Text("On: the timeline keeps loading older posts as you near the end. Off: a Load More button appears instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }


#if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                Section {
                    NavigationLink("Customize Bottom Menu") {
                        BottomMenuEditorView()
                    }
                    Toggle("Menu labels", isOn: $phoneBarShowsLabels)
                        .tint(AccentPresets.current.color)
                } header: {
                    Text("Navigation")
                } footer: {
                    Text("Choose which items join Home in the bottom menu, and their order. Everything else lives in the menu that slides in from the left. Turn off labels for an icons-only menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
#endif

            Section {
                Picker("Appearance", selection: $schemeRaw) {
                    ForEach(AppearanceOption.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Theme")
            } footer: {
                Text("Auto follows the system's light/dark appearance; Light and Dark pin the app to one look.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Color", selection: $accentID) {
                    ForEach(AccentPresets.all) { preset in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(preset.color)
                                .frame(width: 12, height: 12)
                                .overlay(
                                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                                )
                            Text(preset.displayName)
                        }
                        .tag(preset.id)
                    }
                }
            } header: {
                Text("Accent color")
            } footer: {
                Text("Tints buttons, pills, links, and highlights throughout the app. The palette is shared with the {m.txt} editor — quiet, grounded, considered — plus @omic's own Sky.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#if os(iOS)
// MARK: - Bottom Menu Editor
// Mail-style favorites editor: the top section is the bottom bar (Home
// pinned, chosen items removable and drag-reorderable), the bottom section
// is everything living in the side menu, addable with a tap.
private struct BottomMenuEditorView: View {
    @AppStorage(PhoneBarConfig.storageKey) private var barItemsRaw = PhoneBarConfig.defaultValue

    private var barItems: [SidebarItem] {
        Array(PhoneBarConfig.decode(barItemsRaw).prefix(PhoneBarConfig.maxCustomTabs))
    }

    private var sidebarItems: [SidebarItem] {
        let chosen = barItems
        return PhoneBarConfig.eligible.filter { !chosen.contains($0) }
    }

    var body: some View {
        List {
            Section {
                // Home is pinned — always present, always first.
                HStack(spacing: 12) {
                    Image(systemName: SidebarItem.timeline.icon)
                        .frame(width: 28)
                    Text(SidebarItem.timeline.rawValue)
                    Spacer()
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)

                ForEach(barItems) { item in
                    HStack(spacing: 12) {
                        Button {
                            remove(item)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        Image(systemName: item.icon)
                            .frame(width: 28)
                        Text(item.rawValue)
                    }
                }
                .onMove { from, to in
                    var items = barItems
                    items.move(fromOffsets: from, toOffset: to)
                    barItemsRaw = PhoneBarConfig.encode(items)
                }
            } header: {
                Text("Bottom menu")
            } footer: {
                Text("Up to \(PhoneBarConfig.maxCustomTabs) items join Home. Drag to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(sidebarItems) { item in
                    HStack(spacing: 12) {
                        Button {
                            add(item)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(barItems.count >= PhoneBarConfig.maxCustomTabs
                                                 ? Color.secondary : Color.green)
                        }
                        .buttonStyle(.plain)
                        .disabled(barItems.count >= PhoneBarConfig.maxCustomTabs)
                        Image(systemName: item.icon)
                            .frame(width: 28)
                        Text(item.rawValue)
                    }
                }
            } header: {
                Text("Side menu")
            } footer: {
                Text("These stay in the menu that slides in from the left edge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Keeps the reorder handles visible without an Edit button.
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Bottom Menu")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func remove(_ item: SidebarItem) {
        withAnimation {
            barItemsRaw = PhoneBarConfig.encode(barItems.filter { $0 != item })
        }
    }

    private func add(_ item: SidebarItem) {
        guard barItems.count < PhoneBarConfig.maxCustomTabs else { return }
        withAnimation {
            barItemsRaw = PhoneBarConfig.encode(barItems + [item])
        }
    }
}
#endif

// MARK: - Notifications

private struct NotificationsSettingsTab: View {
    private var store: NotificationSettingsStore { .shared }
    /// Bumped after every store mutation so the form re-reads its state.
    @State private var revision = 0

    /// Display metadata for one interaction kind.
    private func label(for reason: NotificationItem.NotificationReason) -> (name: String, icon: String) {
        switch reason {
        case .like:    return ("Likes", "heart")
        case .reply:   return ("Replies", "bubble.left")
        case .mention: return ("Mentions", "at")
        case .repost:  return ("Reposts", "arrow.2.squarepath")
        case .quote:   return ("Quotes", "quote.bubble")
        case .follow:  return ("New Followers", "person.badge.plus")
        case .unknown: return ("Other", "bell")
        }
    }

    var body: some View {
        let _ = revision
        Form {
            Section {
                Toggle("Notify me about interactions", isOn: Binding(
                    get: { store.interactionsEnabled },
                    set: { enabled in
                        store.setInteractionsEnabled(enabled)
                        revision += 1
                        if enabled {
                            // First enable: ask the OS for permission. If
                            // denied, flip the switch back so the UI never
                            // promises notifications that can't arrive.
                            Task { @MainActor in
                                let granted = await Atmo.platform.alertPresenter.requestAuthorization()
                                if !granted {
                                    store.setInteractionsEnabled(false)
                                    revision += 1
                                }
                            }
                        }
                    }
                ))
            } footer: {
                Text("A system-scheduled background check runs every 15 minutes or so — batched with other work the device is already doing, so it doesn't drain the battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(NotificationSettingsStore.notifiableReasons, id: \.rawValue) { reason in
                    let meta = label(for: reason)
                    Toggle(isOn: Binding(
                        get: { store.isReasonEnabled(reason) },
                        set: { store.setReason(reason, enabled: $0); revision += 1 }
                    )) {
                        Label(meta.name, systemImage: meta.icon)
                    }
                    .disabled(!store.interactionsEnabled)
                }
            } header: {
                Text("Interaction kinds")
            } footer: {
                Text("Choose which interactions on your posts and profile send a notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if store.subscriptions.isEmpty {
                    Text("No account subscriptions yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.subscriptions) { subscription in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(subscription.displayName ?? "@\(subscription.handle)")
                                    .lineLimit(1)
                                if subscription.displayName != nil {
                                    Text("@\(subscription.handle)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Picker("", selection: Binding(
                                get: { subscription.mode },
                                set: { newMode in
                                    store.setSubscription(
                                        did: subscription.did,
                                        handle: subscription.handle,
                                        displayName: subscription.displayName,
                                        mode: newMode
                                    )
                                    revision += 1
                                }
                            )) {
                                ForEach([UserPostNotificationMode.allPosts, .originalPostsOnly, .off]) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                }
            } header: {
                Text("Account subscriptions")
            } footer: {
                Text("Accounts you've subscribed to from their profile page (the bell button). \"Original Posts Only\" skips their reposts. Setting an account to Off removes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Accessibility

private struct AccessibilityTab: View {
    @AppStorage(ThemeKeys.solidSurfaces) private var solidSurfaces: Bool = false
    @AppStorage(ThemeKeys.reduceMotion) private var reduceMotion: Bool = false
    @AppStorage(ThemeKeys.textSize) private var textSizeRaw: String = TextSizeOption.standard.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Solid surfaces", isOn: $solidSurfaces)
            } header: {
                Text("Transparency")
            } footer: {
                Text("Replaces translucent card surfaces (quoted posts, link previews, sign-in cards) with opaque fills for better contrast. The system-wide Reduce Transparency setting additionally affects toolbars and floating buttons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Reduce motion", isOn: $reduceMotion)
            } header: {
                Text("Motion")
            } footer: {
                Text("Turns off in-app animations — springy pills, toasts, and transitions snap instead of animating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#if os(iOS)
            Section {
                Picker("Text size", selection: $textSizeRaw) {
                    ForEach(TextSizeOption.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
            } header: {
                Text("Text")
            } footer: {
                Text("Boosts the app's text size beyond your system Dynamic Type setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#endif
        }
        .formStyle(.grouped)
    }
}

// MARK: - Account

private struct AccountTab: View {
    @Environment(ATProtoService.self) private var service
    @State private var showSignOutConfirmation = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Handle") {
                    Text(service.currentHandle.map { "@\($0)" } ?? "—")
                        .textSelection(.enabled)
                }
                LabeledContent("DID") {
                    Text(service.currentUserDID ?? "—")
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } header: {
                Text("Signed in")
            } footer: {
                Text("@omic signs in with a Bluesky App Password. Your session tokens are stored in the Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) {
                    showSignOutConfirmation = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } footer: {
                Text("Signing out removes the stored session from this device. Bookmarks and drafts stay on the device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Sign out of \(service.currentHandle.map { "@\($0)" } ?? "this account")?",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await service.logout() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - About

/// Who made the app, and how to reach them. Everything a person might
/// want to change about the About tab lives here — the blurb, the
/// handle, the address — so none of it is buried in view code.
/// Carried over from the {m.txt} editor's About tab.
private enum DeveloperProfile {
    static let name = "Nathaniel Knudsen (@stoicswe)"
    static let role = "Developer"

    static let blurb = """
        Atmo is a passion project — a calm, native Bluesky client for \
        Apple platforms and Linux. It grew out of wanting a client that \
        feels at home on every screen it runs on: quiet glass surfaces, \
        no clutter, just your timeline.
        """

    static let blueskyHandle = "@stoicswe.com"
    static let blueskyURL = URL(string: "https://bsky.app/profile/stoicswe.com")

    static let email = "contact@stoicswe.com"
    static var emailURL: URL? { URL(string: "mailto:\(email)") }
}

private struct AboutTab: View {
    @StateObject private var tipJar = TipJar()
    @Environment(\.openURL) private var openURL

    // Link's built-in styling and Color.accentColor both resolve to the
    // asset-catalog accent, not the user's chosen preset — so the contact
    // rows style themselves from the stored preset, reactively.
    @AppStorage(ThemeKeys.accentPresetID) private var accentPresetID: String = AccentPresets.defaultID
    private var accent: Color {
        AccentPresets.preset(forID: accentPresetID).color
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 14) {
                        portrait
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DeveloperProfile.name)
                                .font(.headline)
                            Text(DeveloperProfile.role)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(DeveloperProfile.blurb)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)

                contactRow(
                    label: "Bluesky",
                    value: DeveloperProfile.blueskyHandle,
                    systemImage: "at",
                    url: DeveloperProfile.blueskyURL
                )
                contactRow(
                    label: "Email",
                    value: DeveloperProfile.email,
                    systemImage: "envelope",
                    url: DeveloperProfile.emailURL
                )
            } header: {
                Text("About")
            }

            TipJarSection(tipJar: tipJar)

            Section {
            } footer: {
                Text(versionLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .task { await tipJar.prepare() }
    }

    private var portrait: some View {
        Image("DeveloperPortrait")
            .resizable()
            .scaledToFill()
            .frame(width: 64, height: 64)
            .background(Color.primary.opacity(0.05))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func contactRow(
        label: String,
        value: String,
        systemImage: String,
        url: URL?
    ) -> some View {
        if let url {
            Button {
                openURL(url)
            } label: {
                rowBody(label: label, value: value, systemImage: systemImage)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label), \(value)")
        } else {
            rowBody(label: label, value: value, systemImage: systemImage)
        }
    }

    private func rowBody(label: String, value: String, systemImage: String) -> some View {
        HStack {
            Label {
                Text(label)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(accent)
            }
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(accent)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
    }

    /// Read from the app bundle rather than hard-coded, so it can never
    /// drift from what actually shipped.
    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "@omic \(short) (\(build))"
    }
}

// MARK: - Tip jar

/// One tip size. The product IDs must match consumable in-app purchases
/// configured in App Store Connect (and in `Atmo.storekit` for local
/// testing). `fallbackPrice` is only shown when the App Store products
/// can't be loaded — live builds show the store's localized price.
private struct TipTier: Identifiable {
    let id: String
    let emoji: String
    let name: String
    let flavor: String
    let fallbackPrice: String

    static let all: [TipTier] = [
        TipTier(
            id: "com.stoicswe.atmo.tip.small",
            emoji: "🫘",
            name: "Espresso Bean",
            flavor: "A little jolt of encouragement.",
            fallbackPrice: "$0.99"
        ),
        TipTier(
            id: "com.stoicswe.atmo.tip.medium",
            emoji: "☕️",
            name: "Cup o' Joe",
            flavor: "Keeps the commits brewing.",
            fallbackPrice: "$4.99"
        ),
        TipTier(
            id: "com.stoicswe.atmo.tip.large",
            emoji: "🥤",
            name: "Iced Shaken Cold Brew",
            flavor: "Fancy fuel for late-night features.",
            fallbackPrice: "$7.99"
        ),
    ]
}

/// StoreKit 2 wrapper for the tip tiers. Tips are consumables that grant
/// nothing — every purchase is finished immediately and answered with a
/// thank-you. When the store is unreachable (no network, or a build
/// distributed outside the App Store), the tiers render disabled with an
/// explanatory footer instead of failing silently.
@MainActor
private final class TipJar: ObservableObject {
    enum Availability {
        case loading
        case ready
        case unavailable
    }

    @Published private(set) var availability: Availability = .loading
    @Published private(set) var products: [String: Product] = [:]
    /// Product ID of the purchase currently in flight, if any.
    @Published private(set) var purchasingID: String?
    @Published private(set) var thanked = false
    @Published private(set) var pendingApproval = false
    @Published private(set) var lastError: String?

    private var updatesTask: Task<Void, Never>?

    deinit {
        updatesTask?.cancel()
    }

    func prepare() async {
        // Finish any stray transactions (interrupted purchases, Ask to
        // Buy approvals landing later). Tips grant nothing, so finishing
        // — plus a thank-you — is all that's ever needed.
        if updatesTask == nil {
            updatesTask = Task { [weak self] in
                for await update in Transaction.updates {
                    guard case .verified(let transaction) = update else { continue }
                    await transaction.finish()
                    await MainActor.run {
                        self?.thanked = true
                        self?.pendingApproval = false
                    }
                }
            }
        }
        await loadProducts()
    }

    private func loadProducts() async {
        availability = .loading
        do {
            let loaded = try await Product.products(for: TipTier.all.map(\.id))
            guard !loaded.isEmpty else {
                availability = .unavailable
                return
            }
            products = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            availability = .ready
        } catch {
            availability = .unavailable
        }
    }

    /// Localized price for a tier — the store's when loaded, the nominal
    /// USD fallback otherwise.
    func price(for tier: TipTier) -> String {
        products[tier.id]?.displayPrice ?? tier.fallbackPrice
    }

    func tip(_ tier: TipTier) async {
        guard purchasingID == nil, let product = products[tier.id] else { return }
        purchasingID = tier.id
        lastError = nil
        defer { purchasingID = nil }

        do {
            let result = try await purchase(product)
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                }
                thanked = true
                pendingApproval = false
            case .pending:
                pendingApproval = true
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            lastError = "The App Store couldn't complete the tip. Please try again later."
        }
    }

    private func purchase(_ product: Product) async throws -> Product.PurchaseResult {
#if os(macOS)
        // Anchor the App Store confirmation sheet to our window when we
        // have one.
        if let window = NSApp.keyWindow {
            return try await product.purchase(confirmIn: window)
        }
#endif
        return try await product.purchase()
    }
}

private struct TipJarSection: View {
    @ObservedObject var tipJar: TipJar

    var body: some View {
        Section {
            if tipJar.thanked {
                HStack(spacing: 8) {
                    Text("🙏")
                    Text("Thank you for the coffee — it means a lot!")
                        .font(.callout)
                }
                .transition(.opacity)
            }

            ForEach(TipTier.all) { tier in
                tipRow(tier)
            }

            if tipJar.pendingApproval {
                Text("Your tip is awaiting approval — thanks in advance!")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = tipJar.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Tip jar")
        } footer: {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .animation(.easeOut(duration: 0.2), value: tipJar.thanked)
    }

    private func tipRow(_ tier: TipTier) -> some View {
        HStack(spacing: 12) {
            Text(tier.emoji)
                .font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text(tier.name)
                Text(tier.flavor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                Task { await tipJar.tip(tier) }
            } label: {
                if tipJar.purchasingID == tier.id {
                    ProgressView()
                        .controlSize(.small)
                        .frame(minWidth: 48)
                } else {
                    Text(tipJar.price(for: tier))
                        .frame(minWidth: 48)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(tipJar.availability != .ready || tipJar.purchasingID != nil)
        }
        .padding(.vertical, 2)
    }

    private var footerText: String {
        switch tipJar.availability {
        case .ready, .loading:
            return "Tips are one-time thank-yous processed by the App Store. They don't unlock anything — every feature is already yours."
        case .unavailable:
            return "Tips are processed by the App Store and become available when Atmo is installed from the App Store."
        }
    }
}
