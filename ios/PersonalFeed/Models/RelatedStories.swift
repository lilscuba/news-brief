import Foundation

/// "More on this story": other stories about the same event. Clustering sometimes splits one event
/// into several stories, often filed under different topics (a Brazil runoff under World, US and
/// Europe), so this looks across every topic.
///
/// Two headlines are related when they share at least two uncommon words and those words are rare
/// enough together (summed inverse document frequency of at least 12 over the corpus). On the live
/// feed that finds a related story for about a fifth of stories with few false matches.
struct RelatedStories: Sendable {
    static let minSharedWords = 2
    static let minScore = 12.0

    private let stories: [Story]
    private let words: [String: Set<String>]
    private let idf: [String: Double]

    /// `stories` is the corpus to search (and to weigh words against), e.g. every topic's stories.
    init(stories: [Story]) {
        var seen = Set<String>()
        let unique = stories.filter { seen.insert($0.id).inserted }
        self.stories = unique
        var words: [String: Set<String>] = [:]
        var counts: [String: Int] = [:]
        for story in unique {
            let w = Self.words(in: story.title)
            words[story.id] = w
            for word in w { counts[word, default: 0] += 1 }
        }
        self.words = words
        let n = Double(max(unique.count, 1))
        idf = counts.mapValues { log(n / Double($0)) }
    }

    static func find(for story: Story, in stories: [Story], limit: Int = 4) -> [Story] {
        RelatedStories(stories: stories).related(to: story, limit: limit)
    }

    func related(to story: Story, limit: Int = 4) -> [Story] {
        guard !Self.isDeal(story) else { return [] }
        let mine = words[story.id] ?? Self.words(in: story.title)
        guard mine.count >= Self.minSharedWords else { return [] }
        var scored: [(story: Story, score: Double, index: Int)] = []
        for (index, other) in stories.enumerated() where other.id != story.id && !Self.isDeal(other) {
            let shared = mine.intersection(words[other.id] ?? [])
            guard shared.count >= Self.minSharedWords else { continue }
            let score = shared.reduce(0) { $0 + (idf[$1] ?? 0) }
            if score >= Self.minScore { scored.append((other, score, index)) }
        }
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(limit)
            .map(\.story)
    }

    private static func isDeal(_ story: Story) -> Bool {
        story.label == ReliabilityLabel.deal.rawValue || story.category == "Deals"
    }

    /// Lowercased headline words of 3+ letters that carry meaning ("Brazil's" counts as "brazil").
    static func words(in title: String) -> Set<String> {
        let parts = title.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
        return Set(parts.filter { $0.count > 2 && !stopWords.contains($0) && !$0.allSatisfy(\.isNumber) })
    }

    private static let stopWords: Set<String> = [
        "the", "and", "but", "for", "from", "with", "are", "was", "were", "been", "being", "has", "have",
        "had", "does", "did", "its", "this", "that", "these", "those", "she", "they", "you", "his", "her",
        "their", "our", "your", "not", "new", "says", "said", "say", "over", "after", "before", "into",
        "about", "off", "than", "then", "will", "would", "can", "could", "may", "might", "more", "most",
        "first", "last", "just", "also", "amid", "why", "how", "what", "who", "when", "where", "which",
        "while", "via", "one", "two", "three", "year", "years", "week", "day", "days", "today", "news",
        "report", "reports", "old", "now", "here", "out", "all", "get", "gets", "set", "back", "still",
        "least", "some", "people", "time", "live", "update", "updates", "latest", "video", "watch",
    ]
}
