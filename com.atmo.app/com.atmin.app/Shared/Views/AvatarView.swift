import SwiftUI

/// Displays a user avatar from a URL with a placeholder fallback.
struct AvatarView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url = url {
                AsyncCachedImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholderView
                    default:
                        placeholderView
                    }
                }
            } else {
                placeholderView
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholderView: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [AtmoColors.skyBlue.opacity(0.5), Color.indigo.opacity(0.4)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.white.opacity(0.8))
            )
    }
}
