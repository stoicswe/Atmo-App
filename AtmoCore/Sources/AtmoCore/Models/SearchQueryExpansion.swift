import Foundation

// MARK: - Search Query Expansion
/// Builds contextual query variants for a search phrase, so sparse
/// results can be widened invisibly in the background. Mirrors how
/// Bluesky's own search behaves: `searchPosts` treats bare words as a
/// conjunctive keyword match and supports quoted exact phrases, so the
/// variants move along the precision/recall axis:
///
///   1. the exact phrase in quotes (highest precision),
///   2. the phrase stripped to its keyword core — stopwords and
///      headline filler ("underway", "amid", …) removed (higher recall),
///   3. the topic's leading proper noun combined with proper-noun runs
///      from the trend's description ("US Open" + "Travis Scott") —
///      contextual synonyms Bluesky itself supplies with each trend.
///
/// Pure and deterministic; unit-tested.
public enum SearchQueryExpansion {

    /// Common English stopwords plus headline filler that hurts recall
    /// when required as a search keyword.
    static let stopwords: Set<String> = [
        "the", "a", "an", "of", "on", "in", "to", "for", "and", "or",
        "is", "are", "was", "were", "as", "at", "by", "with", "from",
        "after", "before", "amid", "over", "under", "about", "into",
        "its", "his", "her", "their", "this", "that", "these", "those",
        // Headline filler — words trends use that posts rarely repeat.
        "underway", "begins", "begin", "continues", "continue", "says",
        "say", "said", "may", "might", "will", "would", "case", "news",
        "update", "updates", "latest"
    ]

    /// Secondary query variants for `query` (the variant list never
    /// repeats the base query itself — the caller already searched it).
    public static func variants(
        for query: String,
        description: String? = nil,
        limit: Int = 4
    ) -> [String] {
        let base = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return [] }

        var results: [String] = []
        var seen: Set<String> = [base.lowercased()]

        func add(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  seen.insert(trimmed.lowercased()).inserted,
                  results.count < limit else { return }
            results.append(trimmed)
        }

        // 1. Quoted exact phrase (only meaningful for multiword queries).
        if base.contains(" "), !base.contains("\"") {
            add("\"\(base)\"")
        }

        // 2. Keyword core — the phrase without stopwords/filler.
        let words = tokenize(base)
        let core = words.filter { !stopwords.contains($0.lowercased()) }
        if core.count >= 1, core.count < words.count {
            add(core.joined(separator: " "))
        }

        // 3. Contextual terms from the trend's description: proper-noun
        //    runs (≥2 consecutive capitalized words — "Supreme Court",
        //    "Travis Scott"), anchored to the query's own leading proper
        //    nouns so they stay on topic.
        if let description {
            let anchor = leadingProperRun(in: words) ?? core.first ?? words.first ?? ""
            for run in properNounRuns(in: description) {
                guard !base.lowercased().contains(run.lowercased()) else { continue }
                add(anchor.isEmpty ? run : "\(anchor) \(run)")
            }
        }

        return results
    }

    // MARK: Helpers

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map {
            String($0).trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
    }

    private static func isCapitalized(_ word: String) -> Bool {
        word.first?.isUppercase == true
    }

    /// The run of capitalized words the query starts with ("US Open
    /// tennis underway" → "US Open"), or nil when it starts lowercase.
    private static func leadingProperRun(in words: [String]) -> String? {
        var run: [String] = []
        for word in words {
            guard isCapitalized(word) else { break }
            run.append(word)
        }
        return run.count >= 1 ? run.joined(separator: " ") : nil
    }

    /// Every run of ≥2 consecutive capitalized words in the text —
    /// names and places, with single sentence-start capitals naturally
    /// filtered out by the length requirement.
    static func properNounRuns(in text: String) -> [String] {
        let words = tokenize(text)
        var runs: [String] = []
        var current: [String] = []
        for word in words {
            if isCapitalized(word), !stopwords.contains(word.lowercased()) {
                current.append(word)
            } else {
                if current.count >= 2 { runs.append(current.joined(separator: " ")) }
                current = []
            }
        }
        if current.count >= 2 { runs.append(current.joined(separator: " ")) }
        return runs
    }
}
