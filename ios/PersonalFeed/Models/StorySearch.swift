import Foundation

/// Finds stories by words in their headline, summary, outlet or original-language headline.
/// Every word must match somewhere; stories whose headline has every word come first, then the
/// rest, each group in the order given (hot order from the brief).
enum StorySearch {
    static func tokens(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
    }

    static func filter(_ stories: [Story], query: String) -> [Story] {
        let words = tokens(query)
        guard !words.isEmpty else { return [] }
        var seen = Set<String>()
        var inTitle: [Story] = [], elsewhere: [Story] = []
        for story in stories where seen.insert(story.id).inserted {
            if words.allSatisfy({ story.title.localizedStandardContains($0) }) {
                inTitle.append(story)
            } else if words.allSatisfy({ matches(story, $0) }) {
                elsewhere.append(story)
            }
        }
        return inTitle + elsewhere
    }

    private static func matches(_ story: Story, _ word: String) -> Bool {
        if story.title.localizedStandardContains(word) || story.summary.localizedStandardContains(word) {
            return true
        }
        return story.sources.contains { source in
            source.outlet.localizedStandardContains(word)
                || source.title.localizedStandardContains(word)
                || (source.originalTitle?.localizedStandardContains(word) ?? false)
        }
    }
}
