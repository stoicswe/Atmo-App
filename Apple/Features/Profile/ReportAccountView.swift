import SwiftUI
import AtmoCore

// MARK: - ReportAccountView
// The account report sheet, step for step like the official app:
//   1  Why should this user be reviewed?   (category)
//   2  Select a reason
//   3  Select moderation service
//   4  Submit report                        (optional details)
// After a successful report the sheet offers to block the account too.
struct ReportAccountView: View {
    @Bindable var viewModel: ReportAccountViewModel
    /// Already blocking → the post-report block prompt is skipped.
    let isBlocking: Bool
    let onBlock: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()

    private enum Step: Hashable {
        case reason, service, submit
    }

    var body: some View {
        NavigationStack(path: $path) {
            categoryStep
                .navigationTitle("Report @\(viewModel.subjectHandle)")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .reason:  reasonStep
                    case .service: serviceStep
                    case .submit:  submitStep
                    }
                }
        }
#if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 600, idealHeight: 680)
#endif
        .task { await viewModel.loadModerationServices() }
    }

    // MARK: - Step 1: category

    private var categoryStep: some View {
        stepScroll {
            StepHeader(number: 1, title: "Why should this user be reviewed?")

            ForEach(AccountReport.categories) { category in
                OptionCard(
                    title: category.title,
                    subtitle: category.description,
                    isSelected: viewModel.selectedCategory == category
                ) {
                    Haptics.tap()
                    viewModel.selectCategory(category)
                    path.append(Step.reason)
                }
            }

            Link(destination: AccountReport.copyrightSupportURL) {
                HStack(alignment: .top, spacing: AtmoTheme.Spacing.sm) {
                    Text("Need to report a copyright violation, legal request, or regulatory compliance issue?")
                        .font(.subheadline.italic())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .padding(AtmoTheme.Spacing.md)
                .background(cardBackground(selected: false))
            }
            .buttonStyle(.plain)

            upcomingSteps(from: 2)
        }
    }

    // MARK: - Step 2: reason

    private var reasonStep: some View {
        stepScroll {
            if let category = viewModel.selectedCategory {
                completedStep(number: 1, title: category.title)
                StepHeader(number: 2, title: "Select a reason")

                ForEach(category.options) { option in
                    OptionCard(
                        title: option.title,
                        subtitle: nil,
                        isSelected: viewModel.selectedOption == option
                    ) {
                        Haptics.tap()
                        viewModel.selectOption(option)
                        path.append(Step.service)
                    }
                }

                upcomingSteps(from: 3)
            }
        }
        .navigationTitle("Select a reason")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    // MARK: - Step 3: moderation service

    private var serviceStep: some View {
        stepScroll {
            if let category = viewModel.selectedCategory, let option = viewModel.selectedOption {
                completedStep(number: 1, title: category.title)
                completedStep(number: 2, title: option.title)
            }
            StepHeader(number: 3, title: "Select moderation service")

            if viewModel.isLoadingServices, viewModel.services.count <= 1 {
                HStack(spacing: AtmoTheme.Spacing.sm) {
                    ProgressView()
                    Text("Loading your moderation services…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, AtmoTheme.Spacing.sm)
            }

            ForEach(viewModel.availableServices) { service in
                Button {
                    Haptics.tap()
                    viewModel.selectedService = service
                    path.append(Step.submit)
                } label: {
                    HStack(spacing: AtmoTheme.Spacing.md) {
                        AvatarView(url: service.avatarURL, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("@\(service.handle)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if viewModel.selectedService == service {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AtmoColors.accent)
                        }
                    }
                    .padding(AtmoTheme.Spacing.md)
                    .background(cardBackground(selected: viewModel.selectedService == service))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if viewModel.selectedOption?.isBlueskyOnly == true {
                Text("Reports for this reason can only be sent to Bluesky's moderation service.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            upcomingSteps(from: 4)
        }
        .navigationTitle("Moderation service")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
    }

    // MARK: - Step 4: submit

    @ViewBuilder
    private var submitStep: some View {
        if viewModel.didSubmit {
            successView
        } else {
            stepScroll {
                if let category = viewModel.selectedCategory,
                   let option = viewModel.selectedOption,
                   let service = viewModel.selectedService {
                    completedStep(number: 1, title: category.title)
                    completedStep(number: 2, title: option.title)
                    completedStep(number: 3, title: service.name)
                }
                StepHeader(number: 4, title: "Submit report")

                Text(viewModel.selectedOption?.asksForDetails == true
                     ? "Please describe the issue so the moderators can review it."
                     : "Optionally provide additional information below.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if viewModel.details.isEmpty {
                        Text("Additional details")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                    }
                    TextEditor(text: $viewModel.details)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                }
                .padding(AtmoTheme.Spacing.sm)
                .background(cardBackground(selected: false))

                HStack {
                    Spacer()
                    Text("\(viewModel.details.count) / \(AccountReport.detailsMaxLength)")
                        .font(.caption)
                        .foregroundStyle(viewModel.details.count > AccountReport.detailsMaxLength ? .red : .secondary)
                }

                if let error = viewModel.error {
                    Text(error.localizedDescription)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    Haptics.confirm()
                    Task { await viewModel.submit() }
                } label: {
                    HStack {
                        if viewModel.isSubmitting { ProgressView().controlSize(.small) }
                        Text("Send report")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AtmoColors.accent)
                .controlSize(.large)
                .disabled(!viewModel.canSubmit || viewModel.details.count > AccountReport.detailsMaxLength)
            }
            .navigationTitle("Submit report")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
    }

    // MARK: - Success (+ block follow-up)

    private var successView: some View {
        VStack(spacing: AtmoTheme.Spacing.lg) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(AtmoColors.accent)
            Text("Thank you. Your report has been sent.")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            if !isBlocking {
                Text("Would you also like to block @\(viewModel.subjectHandle)? They won't be able to see your posts or interact with you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    Haptics.thump()
                    onBlock()
                    dismiss()
                } label: {
                    Label("Block account", systemImage: "person.crop.circle.badge.xmark")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)

                Button("Not now") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(AtmoColors.accent)
                    .controlSize(.large)
            }
            Spacer()
        }
        .padding(AtmoTheme.Spacing.xl)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Building blocks

    private func stepScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AtmoTheme.Spacing.sm) {
                content()
            }
            .padding(AtmoTheme.Spacing.lg)
        }
    }

    /// Compact line for an already-answered step (tap to go back to it).
    private func completedStep(number: Int, title: String) -> some View {
        HStack(spacing: AtmoTheme.Spacing.sm) {
            StepBadge(number: number, style: .done)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.bottom, AtmoTheme.Spacing.xs)
    }

    /// Greyed-out headings for the steps still ahead.
    private func upcomingSteps(from first: Int) -> some View {
        let titles = [2: "Select a reason", 3: "Select moderation service", 4: "Submit report"]
        return VStack(alignment: .leading, spacing: AtmoTheme.Spacing.md) {
            ForEach(Array(first...4), id: \.self) { n in
                if let title = titles[n] {
                    HStack(spacing: AtmoTheme.Spacing.sm) {
                        StepBadge(number: n, style: .upcoming)
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.top, AtmoTheme.Spacing.lg)
    }

    private func cardBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.secondary.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? AtmoColors.accent : Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }

    private struct StepHeader: View {
        let number: Int
        let title: String
        var body: some View {
            HStack(spacing: AtmoTheme.Spacing.sm) {
                StepBadge(number: number, style: .active)
                Text(title)
                    .font(.title3.weight(.bold))
            }
            .padding(.bottom, AtmoTheme.Spacing.xs)
        }
    }

    private struct StepBadge: View {
        enum Style { case active, done, upcoming }
        let number: Int
        let style: Style
        var body: some View {
            ZStack {
                Circle()
                    .fill(style == .active ? AtmoColors.accent : Color.secondary.opacity(0.15))
                if style == .done {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(style == .active ? Color.white : Color.secondary)
                }
            }
            .frame(width: 24, height: 24)
        }
    }

    private struct OptionCard: View {
        let title: String
        let subtitle: String?
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AtmoTheme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(isSelected ? AtmoColors.accent : Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
