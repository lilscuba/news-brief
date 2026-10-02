import Foundation

/// How stories are ordered inside each list. "Hot topics" is the ranking the feed already comes in
/// (coverage, official sources, recency); "Latest" is newest first.
enum StorySort: String, CaseIterable, Identifiable, Sendable {
    case hot, latest

    static let storageKey = "storySort"

    var id: String { rawValue }
    var title: String { self == .hot ? "Hot topics" : "Latest" }

    /// `stories` arrive in hot order, which is also the tie-break for stories published at the
    /// same moment.
    func apply(_ stories: [Story]) -> [Story] {
        switch self {
        case .hot:
            return stories
        case .latest:
            return stories.enumerated().sorted { l, r in
                l.element.published != r.element.published
                    ? l.element.published > r.element.published
                    : l.offset < r.offset
            }.map(\.element)
        }
    }
}
