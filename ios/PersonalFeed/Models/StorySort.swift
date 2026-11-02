import Foundation

/// How stories are ordered inside each list. "For you" (the default) shuffles what you haven't
/// seen and moves what you scrolled past or read to the bottom (see FeedOrder); "Hot topics" is
/// the ranking the feed already comes in (coverage, official sources, recency); "Latest" is
/// newest first.
enum StorySort: String, CaseIterable, Identifiable, Sendable {
    case forYou, hot, latest

    /// A new key for the build that added For you, so everyone starts on it once; "storySort"
    /// held Hot topics or Latest before.
    static let storageKey = "feedSort"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forYou: "For you"
        case .hot: "Hot topics"
        case .latest: "Latest"
        }
    }

    /// `stories` arrive in hot order, which is also the tie-break for stories published at the
    /// same moment. For you needs the reader's state (`order`); without it, it keeps hot order.
    func apply(_ stories: [Story], order: FeedOrder? = nil) -> [Story] {
        switch self {
        case .forYou:
            return order?.apply(stories) ?? stories
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

    /// Groups a list into "Last hour", "Earlier today", "Yesterday" and "Older", keeping the
    /// order within each group. Empty groups are left out. Used for the Latest view, where one
    /// flat list of 200 rows gives no sense of how current it is.
    static func buckets(_ stories: [Story], now: Date = .now,
                        calendar: Calendar = .current) -> [StoryBucket] {
        var groups: [StoryBucket.Kind: [Story]] = [:]
        let hourAgo = now.addingTimeInterval(-3600)
        for story in stories {
            let kind: StoryBucket.Kind
            if story.published >= hourAgo {
                kind = .lastHour
            } else if calendar.isDate(story.published, inSameDayAs: now) {
                kind = .earlierToday
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(story.published, inSameDayAs: yesterday) {
                kind = .yesterday
            } else {
                kind = .older
            }
            groups[kind, default: []].append(story)
        }
        return StoryBucket.Kind.allCases.compactMap { kind in
            groups[kind].map { StoryBucket(kind: kind, stories: $0) }
        }
    }
}

/// One time group of a Latest list.
struct StoryBucket: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case lastHour, earlierToday, yesterday, older
    }

    let kind: Kind
    let stories: [Story]
    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .lastHour: "Last hour"
        case .earlierToday: "Earlier today"
        case .yesterday: "Yesterday"
        case .older: "Older"
        }
    }
}
