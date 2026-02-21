import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section {
                // Placeholder — settings options will go here
                Label("Nothing here yet", systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
            } header: {
                Text("General")
            }
        }
        .navigationTitle("Settings")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
#endif
#if os(iOS)
        .listStyle(.insetGrouped)
#else
        .listStyle(.inset)
#endif
    }
}
