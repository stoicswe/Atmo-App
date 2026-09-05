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

        // Verified accounts' posts lead the sample and are marked in the
        // prompt — the model is told to weight them more heavily.
        let sample = TopicSummaryStore.prioritizedSample(posts, limit: 25).map { post in
            let marker = post.authorVerification != nil ? "[verified] " : ""
            return "- " + marker + post.displayText
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
            preamble, no hashtags, no quotation of usernames. Posts marked \
            [verified] come from verified accounts — weight them more \
            heavily than unmarked posts when deciding what is accurate and \
            what the topic is really about.
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
                // Liquid Glass card: the house glassCard (refraction, edge
                // highlight, Solid Surfaces fallback) with an accent rim and
                // the sparkles on their own tinted glass disc, so the card
                // reads as a floating control rather than a shaded row.
                let shape = RoundedRectangle(cornerRadius: AtmoTheme.CornerRadius.large, style: .continuous)
                VStack(alignment: .leading, spacing: AtmoTheme.Spacing.sm) {
                    HStack(spacing: AtmoTheme.Spacing.sm) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .glassEffect(.regular.tint(AtmoColors.accent.opacity(0.85)), in: Circle())
                            .symbolEffect(.pulse, isActive: summarizer.isStreaming)
                        Text("Topic summary")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if summarizer.isStreaming {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Spacer(minLength: 0)
                    }

                    Text(summarizer.text.isEmpty ? "Summarizing…" : summarizer.text)
                        .font(.subheadline)
                        .foregroundStyle(summarizer.text.isEmpty ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.interpolate)
                        .animation(.easeOut(duration: 0.2), value: summarizer.text)

                    HStack(spacing: 4) {
                        Image(systemName: "apple.intelligence")
                            .font(.caption2)
                        Text("Generated by Apple Intelligence on this device.")
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                }
                .padding(AtmoTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: AtmoTheme.CornerRadius.large)
                .overlay {
                    // Accent rim catching the light along the top edge.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [AtmoColors.accent.opacity(0.45), AtmoColors.accent.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
                .compositingGroup()
                .shadow(color: AtmoColors.accent.opacity(0.14), radius: 16, y: 6)
                .padding(.horizontal, AtmoTheme.Feed.horizontalPadding)
                .padding(.vertical, AtmoTheme.Spacing.md)
            } else {
                // The card starts with nothing to show — the summary only
                // exists once the task below generates it. An `if` with no
                // else resolved to EmptyView here, and SwiftUI never fires
                // .task/.onAppear on EmptyView: no view → no task → no
                // text → no view, a deadlock where the summary never
                // appeared. This invisible 1pt placeholder is a real
                // layout node, so the task actually starts.
                Color.clear.frame(height: 1)
            }
        }
        // Keyed on topic AND a coarse posts-readiness bucket. The card
        // mounts the moment a topic is tapped, while posts are still
        // loading — a task keyed on the topic alone ran once with an
        // empty list, failed the minimum-posts guard, and never retried.
        // The bucket (none → some → plenty) re-runs it as material
        // arrives, while staying deliberately coarse for efficiency: the
        // on-device model runs at most twice per topic, and the second
        // run happens only when background enrichment grew a sparse
        // sample into a rich one. A rich first sample starts at the top
        // bucket, so later corpus growth triggers no extra inference.
        .task(id: "\(topic)|\(posts.count >= 25 ? 2 : (posts.count >= 3 ? 1 : 0))") {
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
