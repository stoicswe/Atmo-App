#if os(iOS)
import SwiftUI
import PassKit
import CoreImage
import CoreImage.CIFilterBuiltins
import AtmoCore

// MARK: - WalletPassSheet
/// Pick a look, see the card, add it to Wallet. iOS 27 only: the pass is
/// designed around Wallet's poster layout (full-card artwork, QR in the
/// middle, fields along the bottom), which older Wallets don't draw.
@available(iOS 27, *)
struct WalletPassSheet: View {
    let handle: String
    let did: String
    let memberSince: Date?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("atmo.walletPass.theme") private var themeID = WalletPassTheme.sky.id
    @State private var isBuilding = false
    @State private var errorMessage: String?
    @State private var pendingPass: PendingPass?

    private var theme: WalletPassTheme { WalletPassTheme.builtIn(id: themeID) ?? .sky }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AtmoTheme.Spacing.xl) {
                    WalletPassPreview(handle: handle, did: did, memberSince: memberSince, theme: theme)
                        .frame(maxWidth: 300)
                        .padding(.top, AtmoTheme.Spacing.sm)

                    themePicker

                    if let credit = theme.credit {
                        if let url = theme.creditURL {
                            Link(destination: url) {
                                Label(credit, systemImage: "camera")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            Label(credit, systemImage: "camera")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    AddPassButton(action: addToWallet)
                        .frame(width: 220, height: 48)
                        .disabled(isBuilding || !WalletPassAvailability.canSign)
                        .opacity(isBuilding ? 0.5 : 1)
                        .overlay {
                            if isBuilding { ProgressView().tint(.white) }
                        }

                    Text("The card's QR code opens your Bluesky profile at bsky.app. Adding it again with a different look replaces the card in Wallet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            }
            .navigationTitle("Wallet Pass")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $pendingPass) { pending in
                AddPassesController(pass: pending.pass) { pendingPass = nil }
                    .ignoresSafeArea()
            }
        }
    }

    private var themePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AtmoTheme.Spacing.md) {
                ForEach(WalletPassTheme.builtIn) { candidate in
                    ThemeChip(theme: candidate, isSelected: candidate.id == themeID) {
                        themeID = candidate.id
                        Haptics.tap()
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private func addToWallet() {
        guard let signer = WalletPassCredentials.signer else {
            errorMessage = WalletPassError.credentialsUnavailable.localizedDescription
            return
        }
        isBuilding = true
        errorMessage = nil
        let (handle, did, memberSince, theme) = (handle, did, memberSince, theme)
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try WalletPassGenerator.makePass(handle: handle, did: did, memberSince: memberSince, theme: theme, signer: signer)
                }.value
                pendingPass = PendingPass(pass: try PKPass(data: data))
            } catch {
                errorMessage = error.localizedDescription
            }
            isBuilding = false
        }
    }

    private struct PendingPass: Identifiable {
        let id = UUID()
        let pass: PKPass
    }
}

// MARK: - Theme chip
private struct ThemeChip: View {
    let theme: WalletPassTheme
    let isSelected: Bool
    let action: () -> Void

    private let shape = RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous)

    var body: some View {
        Button(action: action) {
            VStack(spacing: AtmoTheme.Spacing.xs) {
                WalletPassArtwork(theme: theme)
                    .frame(width: 64, height: 80)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(borderColor, lineWidth: 3))
                Text(theme.name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(theme.name) look"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var borderColor: Color { isSelected ? AtmoColors.accent : Color.clear }
}

// MARK: - Preview card
/// A SwiftUI stand-in for Wallet's poster layout so the picker shows
/// roughly what the card will look like.
private struct WalletPassPreview: View {
    let handle: String
    let did: String
    let memberSince: Date?
    let theme: WalletPassTheme

    @State private var qrImage: UIImage?

    var body: some View {
        ZStack {
            WalletPassArtwork(theme: theme)

            VStack(spacing: 0) {
                HStack {
                    if let logoURL = WalletPassGenerator.primaryLogoURL(), let logo = UIImage(contentsOfFile: logoURL.path) {
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 26)
                    }
                    Spacer()
                }
                .padding(AtmoTheme.Spacing.lg)

                Spacer(minLength: 0)

                VStack(spacing: AtmoTheme.Spacing.xs) {
                    if let qrImage {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 132, height: 132)
                    } else {
                        Color.clear.frame(width: 132, height: 132)
                    }
                    Text(handle)
                        .font(.caption)
                        .foregroundStyle(.black)
                        .lineLimit(1)
                }
                .padding(AtmoTheme.Spacing.sm)
                .background(Color.white, in: RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.small, style: .continuous))

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: AtmoTheme.Spacing.sm) {
                    HStack(alignment: .top) {
                        field(label: "Handle", value: handle, alignment: .leading)
                        Spacer(minLength: AtmoTheme.Spacing.md)
                        if let memberSince {
                            field(label: "Member Since", value: memberSince.formatted(date: .numeric, time: .omitted), alignment: .trailing)
                        }
                    }
                    Text(did)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(labelColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(AtmoTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .aspectRatio(358 / 448, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.large, style: .continuous))
        .shadow(color: AtmoTheme.Shadow.card.color, radius: AtmoTheme.Shadow.card.radius, x: AtmoTheme.Shadow.card.x, y: AtmoTheme.Shadow.card.y)
        .task(id: handle) {
            qrImage = Self.makeQR(WalletPassDocument.profileURL(handle: handle))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Wallet pass preview, \(theme.name) look, for @\(handle)"))
    }

    private var foregroundColor: Color { Color(theme.foregroundColor) }
    private var labelColor: Color { Color(theme.labelColor) }

    private func field(label: String, value: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(labelColor)
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
        }
    }

    /// Same content Wallet renders from the pass's barcode entry.
    nonisolated static func makeQR(_ message: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The theme's artwork, falling back to its flat colour when the PNG
/// isn't bundled.
private struct WalletPassArtwork: View {
    let theme: WalletPassTheme

    var body: some View {
        if let url = WalletPassGenerator.artworkURL(for: theme), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Color(theme.backgroundColor)
        }
    }
}

private extension Color {
    init(_ rgb: WalletPassTheme.RGB) {
        self.init(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}

// MARK: - PassKit bridges

/// Apple's own "Add to Apple Wallet" button.
private struct AddPassButton: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> PKAddPassButton {
        let button = PKAddPassButton(addPassButtonStyle: .black)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: PKAddPassButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

/// Wallet's review-and-add screen for a built pass.
private struct AddPassesController: UIViewControllerRepresentable {
    let pass: PKPass
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard let controller = PKAddPassesViewController(pass: pass) else {
            return UIViewController()
        }
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, PKAddPassesViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
            onFinish()
        }
    }
}
#endif
