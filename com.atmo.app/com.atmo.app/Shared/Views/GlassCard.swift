import SwiftUI

/// A reusable glass card container using the Liquid Glass design system.
/// Wraps content with `.glassEffect()` and proper corner radius.
struct GlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        cornerRadius: CGFloat = AtmoTheme.CornerRadius.large,
        padding: CGFloat = AtmoTheme.Spacing.lg,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .glassCard(cornerRadius: cornerRadius)
    }
}
