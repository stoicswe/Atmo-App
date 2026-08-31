import SwiftUI
import AtmoCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Topic Summarizer
/// On-device topic summaries via Apple Intelligence (FoundationModels).
/// Feeds the top posts of a tapped topic to the system language model and
/// streams the summary as it generates. Runs entirely on device; the
/// posts never leave it. On hardware with the advanced on-device model
/// (iPhone 17 Pro-class), the OS serves that model automatically.
@MainActor
@Observable
final class TopicSummarizer {

    private(set) var text = ""
    private(set) var isStreaming = false

    /// Whether this device can generate summaries at all.
    static var isSupported: Bool {
#if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
#else
        return false
#endif
    }

    /// True when the OS serves Apple's advanced on-device model
    /// (newer-generation hardware — iPhone 17 Pro class, iOS 27+).
    ///
    /// The `variant` API only exists in 27-era SDKs, and `#available` is a
    /// RUNTIME check — building with a 26-era SDK (Xcode Cloud's stable
    /// toolchain, Build 24's failure) needs this COMPILE-time gate too:
    /// stable Xcode 26.x ships Swift 6.3, the 27 toolchain ships 6.4.
    static var usesAdvancedModel: Bool {
#if canImport(FoundationModels) && os(iOS) && compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return SystemLanguageModel.default.variant == .coreAdvanced3
        }
#endif
        return false
    }

    /// Summarizes the topic from its top posts. When `streamIntoUI` the
    /// text fills in live token by token; otherwise (background accuracy
    /// refresh over a cached summary) the display only updates once the
    /// new summary completes. The result is cached for three days.
    func summarize(topic: String, posts: [PostItem], streamIntoUI: Bool) async {
#if canImport(FoundationModels)
        guard Self.isSupported, posts.count >= 3 else { return }

        let sample = posts.prefix(25).map { post in
            "- " + post.displayText
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(280)
        }
        let prompt = """
        Here are popular recent Bluesky posts about "\(topic)":
        \(sample.joined(separator: "\n"))
        Write a neutral 2–3 sentence summary of what is happening with this topic.
        """

        let session = LanguageModelSession(instructions: """
            You summarize what people on social media are discussing about \
            a topic. Be factual, neutral, and concise: 2–3 sentences, no \
            preamble, no hashtags, no quotation of usernames.
            """)

        if streamIntoUI { isStreaming = true }
        defer { isStreaming = false }
        do {
            var final = ""
            for try await partial in session.streamResponse(to: prompt) {
                final = partial.content
                if streamIntoUI {
                    text = final
                }
            }
            let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            TopicSummaryStore.shared.save(topic: topic, text: trimmed)
            // Background refreshes swap in the up-to-date summary once done.
            text = trimmed
        } catch {
            // Guardrail refusals or interruptions — keep whatever we have.
        }
#endif
    }
}

// MARK: - Topic Summary Card
/// Sits at the top of the post results for a tapped topic: streams the
/// Apple Intelligence summary in as it generates, or shows the cached one
/// instantly (with a silent background re-analysis for accuracy).
struct TopicSummaryCard: View {
    let topic: String
    let posts: [PostItem]

    @AppStorage(TopicSummaryStore.enabledKey) private var summariesEnabled = false
    @State private var summarizer = TopicSummarizer()

    var body: some View {
        Group {
            if summariesEnabled, TopicSummarizer.isSupported,
               !summarizer.text.isEmpty || summarizer.isStreaming {
                VStack(alignment: .leading, spacing: AtmoTheme.Spacing.sm) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AtmoColors.accent)
                        Text("Topic summary")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if summarizer.isStreaming {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Spacer(minLength: 0)
                    }

                    Text(summarizer.text.isEmpty ? "Summarizing…" : summarizer.text)
                        .font(.subheadline)
                        .foregroundStyle(summarizer.text.isEmpty ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.interpolate)
                        .animation(.easeOut(duration: 0.2), value: summarizer.text)

                    Text("Generated by Apple Intelligence on this device.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(AtmoTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.medium, style: .continuous)
                        .fill(AtmoColors.accent.opacity(0.06))
                )
                .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
                .padding(.vertical, AtmoTheme.Spacing.sm)
            }
        }
        .task(id: topic) {
            guard summariesEnabled, TopicSummarizer.isSupported else { return }
            if let cached = TopicSummaryStore.shared.summary(for: topic), cached.isFresh {
                // Cached: display instantly, then re-analyze silently so
                // the summary stays accurate; the refresh replaces the
                // text (and the cache) only once it completes.
                summarizer.summarizeCachedFirst(cached.text)
                await summarizer.summarize(topic: topic, posts: posts, streamIntoUI: false)
            } else {
                await summarizer.summarize(topic: topic, posts: posts, streamIntoUI: true)
            }
        }
    }
}

extension TopicSummarizer {
    /// Seeds the display with a cached summary before a silent refresh.
    func summarizeCachedFirst(_ cached: String) {
        text = cached
    }
}
