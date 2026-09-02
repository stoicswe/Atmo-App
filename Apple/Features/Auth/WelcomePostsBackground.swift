import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Welcome greetings
// Each floating card is a tiny fake post: the language name where the
// author's name would go, and "Welcome" written in that language.

private let welcomeGreetings: [(language: String, text: String)] = [
    ("English",     "Welcome"),
    ("Spanish",     "Bienvenido"),
    ("French",      "Bienvenue"),
    ("German",      "Willkommen"),
    ("Italian",     "Benvenuto"),
    ("Portuguese",  "Bem-vindo"),
    ("Dutch",       "Welkom"),
    ("Swedish",     "Välkommen"),
    ("Danish",      "Velkommen"),
    ("Norwegian",   "Velkommen"),
    ("Finnish",     "Tervetuloa"),
    ("Icelandic",   "Velkomin"),
    ("Polish",      "Witamy"),
    ("Czech",       "Vítejte"),
    ("Slovak",      "Vitajte"),
    ("Hungarian",   "Üdvözöljük"),
    ("Romanian",    "Bine ați venit"),
    ("Greek",       "Καλώς ήρθατε"),
    ("Russian",     "Добро пожаловать"),
    ("Ukrainian",   "Ласкаво просимо"),
    ("Bulgarian",   "Добре дошли"),
    ("Serbian",     "Добродошли"),
    ("Croatian",    "Dobrodošli"),
    ("Turkish",     "Hoş geldiniz"),
    ("Arabic",      "أهلاً وسهلاً"),
    ("Hebrew",      "ברוכים הבאים"),
    ("Persian",     "خوش آمدید"),
    ("Hindi",       "स्वागत है"),
    ("Bengali",     "স্বাগতম"),
    ("Tamil",       "வரவேற்கிறோம்"),
    ("Urdu",        "خوش آمدید"),
    ("Thai",        "ยินดีต้อนรับ"),
    ("Vietnamese",  "Chào mừng"),
    ("Indonesian",  "Selamat datang"),
    ("Malay",       "Selamat datang"),
    ("Tagalog",     "Maligayang pagdating"),
    ("Japanese",    "ようこそ"),
    ("Korean",      "환영합니다"),
    ("Chinese",     "欢迎"),
    ("Cantonese",   "歡迎"),
    ("Swahili",     "Karibu"),
    ("Amharic",     "እንኳን ደህና መጡ"),
    ("Zulu",        "Siyakwamukela"),
    ("Hawaiian",    "E komo mai"),
    ("Māori",       "Nau mai"),
    ("Irish",       "Fáilte"),
    ("Welsh",       "Croeso"),
    ("Catalan",     "Benvingut"),
    ("Basque",      "Ongi etorri"),
    ("Latin",       "Salve"),
    ("Esperanto",   "Bonvenon"),
    ("Georgian",    "კეთილი იყოს თქვენი მობრძანება"),
    ("Armenian",    "Բարի գալուստ"),
    ("Mongolian",   "Тавтай морил"),
]

// MARK: - Floating card model

private struct FloatingCard: Identifiable {
    let id: UUID
    let language: String
    let text: String
    let xFraction: CGFloat
    let yFraction: CGFloat
    let rotation: Double
    var opacity: Double = 0
}

// MARK: - Single card

/// A miniature post: avatar disc with the language's initial, the
/// language as the display name, a handle line, the greeting as the post
/// text, and a faint action row — the feed in thumbnail form.
private struct WelcomeCardView: View {
    let card: FloatingCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(AtmoColors.accent.opacity(0.28))
                    .frame(width: 20, height: 20)
                    .overlay {
                        Text(String(card.language.prefix(1)))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(AtmoColors.accent)
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(card.language)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("@welcome")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("now")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }

            Text(card.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                Image(systemName: "bubble.left")
                Image(systemName: "arrow.2.squarepath")
                Image(systemName: "heart")
                Spacer(minLength: 0)
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.top, 1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: 172, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
                )
        )
        .fixedSize()
        .rotationEffect(.degrees(card.rotation))
    }
}

// MARK: - Animated background

/// Floating welcome posts behind the sign-in form. Cards drift in one by
/// one, hold at a soft opacity for a while, then fade out and are
/// replaced — never more than a couple appearing or leaving at once.
struct WelcomePostsBackground: View {
    @State private var cards: [FloatingCard] = []

    /// Chosen once: how many cards to fill up to in the initial burst.
    private let initialTarget: Int = Int.random(in: 10...18)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(cards) { card in
                    WelcomeCardView(card: card)
                        .position(
                            x: card.xFraction * geo.size.width,
                            y: card.yFraction * geo.size.height
                        )
                        .opacity(card.opacity)
                }
            }
            .task {
                // Phase 1: initial fill, staggered so cards arrive one by
                // one. geo.size is re-read each pass so a pre-layout zero
                // size is never locked in.
                var spawned = 0
                while spawned < initialTarget {
                    guard !Task.isCancelled else { return }
                    let size = geo.size
                    guard size.width > 0, size.height > 0 else {
                        try? await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    spawn(in: size)
                    spawned += 1
                    try? await Task.sleep(for: .seconds(Double.random(in: 0.25...0.9)))
                }

                // Phase 2: trickle replacements as cards fade out.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 1.8...4.0)))
                    guard !Task.isCancelled else { return }
                    spawn(in: geo.size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @MainActor
    private func spawn(in size: CGSize) {
        guard size.width > 0, size.height > 0, cards.count < 20 else { return }
        let greeting = welcomeGreetings.randomElement()!
        let id = UUID()
        let card = FloatingCard(
            id: id,
            language: greeting.language,
            text: greeting.text,
            xFraction: CGFloat.random(in: 0.08...0.92),
            yFraction: CGFloat.random(in: 0.05...0.95),
            rotation: Double.random(in: -6...6)
        )
        cards.append(card)

        withAnimation(.easeIn(duration: Double.random(in: 1.8...3.5))) {
            setOpacity(id, to: Double.random(in: 0.38...0.6))
        }

        let lifetime = Double.random(in: 10.0...22.0)
        let fadeOut = Double.random(in: 2.5...6.0)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(lifetime))
            withAnimation(.easeOut(duration: fadeOut)) {
                setOpacity(id, to: 0)
            }
            try? await Task.sleep(for: .seconds(fadeOut + 0.1))
            cards.removeAll { $0.id == id }
        }
    }

    private func setOpacity(_ id: UUID, to value: Double) {
        if let i = cards.firstIndex(where: { $0.id == id }) {
            cards[i].opacity = value
        }
    }
}

// MARK: - Grouped background color
/// The plain system grouped ground the cards float over (Grit's base).
extension Color {
    static var loginGround: Color {
#if os(iOS)
        Color(uiColor: .systemGroupedBackground)
#else
        Color(nsColor: .windowBackgroundColor)
#endif
    }
}
