// Not compiled for watchOS: this file ships with the Platform folder the
// watch target shares, but the family stack (and the app's design system
// types used here) are iPhone/Mac-only.
#if !os(watchOS)
import SwiftUI
import AtmoCore
#if canImport(DeclaredAgeRange)
import DeclaredAgeRange
#endif
#if canImport(PermissionKit)
import PermissionKit
#endif

// MARK: - Family Age Probe
/// Bridges Apple's family stack into the app:
///  • Declared Age Range — asks the system for the account holder's age
///    bracket (a parent shares it for child accounts; adults see a consent
///    prompt once) and feeds it into `ParentalControlsStore`.
///  • PermissionKit — listens for parents' answers to ask-to-message
///    requests and records approvals.
struct FamilyControlsIntegration: ViewModifier {
#if canImport(DeclaredAgeRange)
    @Environment(\.requestAgeRange) private var requestAgeRange
#endif
    /// One shot per install; the Settings "Check Family Settings" button
    /// clears it to re-probe.
    @AppStorage(Self.probedKey) private var hasProbed = false

    static let probedKey = "atmo.parental.hasProbedAgeRange"

    func body(content: Content) -> some View {
        content
            .task { await probeIfNeeded() }
            .task { await listenForParentResponses() }
            // Settings' "Check Family Settings" clears the flag to re-probe.
            .onChange(of: hasProbed) { _, probed in
                guard !probed else { return }
                Task { await probeIfNeeded() }
            }
    }

    @MainActor
    private func probeIfNeeded() async {
#if canImport(DeclaredAgeRange)
        guard !hasProbed else { return }
        do {
            // Gates at 13 and 18 → child / teen / adult brackets.
            let response = try await requestAgeRange(ageGates: 13, 18)
            hasProbed = true
            switch response {
            case .sharing(let range):
                ParentalControlsStore.shared.setAgeCategory(
                    AgeCategory.from(lowerBound: range.lowerBound, upperBound: range.upperBound)
                )
            case .declinedSharing:
                ParentalControlsStore.shared.setAgeCategory(.unknown)
            @unknown default:
                break
            }
        } catch {
            // Not signed into iCloud / feature unavailable — stay unknown.
            // Mark probed anyway so launches don't nag; Settings offers a
            // manual re-check.
            hasProbed = true
        }
#endif
    }

    /// Parents answer ask-to-message requests in Messages; the responses
    /// arrive here whenever the app is running.
    @MainActor
    private func listenForParentResponses() async {
#if canImport(PermissionKit)
        for await response in AskCenter.shared.responses(for: CommunicationTopic.self) {
            let approved = response.choice.answer == .approval
            for person in response.question.topic.personInformation {
                ParentalControlsStore.shared.recordParentDMDecision(
                    handle: person.handle.value,
                    approved: approved
                )
            }
        }
#endif
    }
}

extension View {
    /// Installs the Declared Age Range probe and the PermissionKit
    /// response listener. Apply once, at the app's root.
    func integratesFamilyControls() -> some View {
        modifier(FamilyControlsIntegration())
    }
}

// MARK: - Ask-to-Message Sheet
/// Shown when a managed child account tries to start a NEW conversation:
/// explains the rule and offers the system ask-a-parent flow (the request
/// lands in the parent's Messages). Approval is recorded by the response
/// listener above; conversations already approved skip this sheet.
struct AskToDMSheet: View {
    let handle: String
    let displayName: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: AtmoTheme.Spacing.lg) {
                Spacer(minLength: 0)

                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 52))
                    .foregroundStyle(AtmoColors.accent)

                Text("Ask to message \(displayName ?? "@\(handle)")?")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Your Family settings require a parent's OK before starting new chats. Send a request — it shows up in their Messages.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

#if canImport(PermissionKit)
                CommunicationLimitsButton(
                    question: PermissionQuestion(
                        handle: CommunicationHandle(value: handle, kind: .custom)
                    )
                ) {
                    Label("Ask Permission", systemImage: "paperplane.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AtmoColors.accent)
#else
                Text("Ask-a-parent requests aren't available on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
#endif

                Spacer(minLength: 0)
            }
            .padding(AtmoTheme.Spacing.xl)
            .navigationTitle("New Chat")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 380, minHeight: 380)
#endif
    }
}
#endif
