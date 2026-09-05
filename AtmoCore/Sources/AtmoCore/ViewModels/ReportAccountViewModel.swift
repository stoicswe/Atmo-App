import Foundation
import ATProtoKit
import Observation

// MARK: - ReportAccountViewModel
// Drives the four-step account report sheet, mirroring the official app:
//   1. Why should this user be reviewed?  (category)
//   2. Select a reason                    (Ozone reason type)
//   3. Select moderation service          (Bluesky + subscribed labelers)
//   4. Submit report                      (optional details, then send)
// The report is a `com.atproto.moderation.createReport` call proxied to
// the chosen labeler via the `atproto-proxy` header (`did#atproto_labeler`),
// with a `repoRef` subject for the account.
@Observable
@MainActor
public final class ReportAccountViewModel: Identifiable {

    /// One report sheet per subject account — lets SwiftUI present it via `.sheet(item:)`.
    public nonisolated var id: String { subjectDID }

    public let subjectDID: String
    public let subjectHandle: String

    public var selectedCategory: AccountReport.Category? = nil
    public var selectedOption: AccountReport.Option? = nil
    public var selectedService: ModerationServiceInfo? = nil
    public var details: String = ""

    public private(set) var services: [ModerationServiceInfo] = [.bluesky]
    public private(set) var isLoadingServices = false
    public private(set) var isSubmitting = false
    public private(set) var didSubmit = false
    public private(set) var error: Error? = nil

    private let service: ATProtoService

    public init(service: ATProtoService, subjectDID: String, subjectHandle: String) {
        self.service = service
        self.subjectDID = subjectDID
        self.subjectHandle = subjectHandle
    }

    /// Services the selected reason may be sent to — some reasons are
    /// restricted to Bluesky's own moderation service.
    public var availableServices: [ModerationServiceInfo] {
        if selectedOption?.isBlueskyOnly == true {
            return services.filter(\.isBluesky)
        }
        return services
    }

    public var canSubmit: Bool {
        selectedOption != nil && selectedService != nil && !isSubmitting && !didSubmit
    }

    public func selectCategory(_ category: AccountReport.Category) {
        selectedCategory = category
        selectedOption = nil
        selectedService = nil
    }

    public func selectOption(_ option: AccountReport.Option) {
        selectedOption = option
        if let current = selectedService, !availableServices.contains(current) {
            selectedService = nil
        }
    }

    // MARK: - Moderation services

    /// Bluesky's service first, then the labelers in the account's
    /// preferences, resolved to display info through getProfiles. Any
    /// failure degrades to Bluesky-only rather than blocking the report.
    public func loadModerationServices() async {
        guard !isLoadingServices, let kit = service.atProtoKit else { return }
        isLoadingServices = true
        defer { isLoadingServices = false }

        var dids: [String] = [AccountReport.blueskyModerationDID]
        if let prefs = try? await kit.getPreferences() {
            for pref in prefs.preferences {
                if case .labelersPreferences(let labelers) = pref {
                    for item in labelers.labelers where !dids.contains(item.did) {
                        dids.append(item.did)
                    }
                }
            }
        }

        var resolved: [ModerationServiceInfo] = []
        if let output = try? await kit.getProfiles(for: dids) {
            let byDID = Dictionary(uniqueKeysWithValues: output.profiles.map { ($0.actorDID, $0) })
            for did in dids {
                if let p = byDID[did] {
                    resolved.append(ModerationServiceInfo(
                        did: did,
                        handle: p.actorHandle,
                        displayName: p.displayName,
                        avatarURL: p.avatarImageURL
                    ))
                } else if did == AccountReport.blueskyModerationDID {
                    resolved.append(.bluesky)
                }
            }
        }
        if resolved.isEmpty { resolved = [.bluesky] }
        services = resolved
        if selectedService == nil, availableServices.count == 1 {
            selectedService = availableServices.first
        }
    }

    // MARK: - Submit

    public func submit() async {
        guard let option = selectedOption,
              let target = selectedService,
              let kit = service.atProtoKit else { return }
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }

        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ComAtprotoLexicon.Moderation.CreateReportRequestBody(
            reasonType: option.reason,
            reason: trimmed.isEmpty ? nil : String(trimmed.prefix(AccountReport.detailsMaxLength)),
            subject: .repositoryReference(.init(repositoryDID: subjectDID))
        )

        do {
            guard let session = try await kit.getUserSession() else {
                throw AtmoError.notAuthenticated
            }
            let base = session.serviceEndpoint.absoluteString
            guard let url = URL(string: "\(base)/xrpc/com.atproto.moderation.createReport") else {
                throw AtmoError.unknown(underlying: URLError(.badURL))
            }
            let request = kit.apiClientService.createRequest(
                forRequest: url,
                andMethod: .post,
                acceptValue: "application/json",
                contentTypeValue: "application/json",
                requiresAuthorization: true,
                proxyValue: "\(target.did)#atproto_labeler"
            )
            _ = try await kit.apiClientService.sendRequest(
                request,
                withEncodingBody: body,
                decodeTo: ComAtprotoLexicon.Moderation.CreateReportOutput.self
            )
            didSubmit = true
        } catch {
            self.error = error
        }
    }
}
