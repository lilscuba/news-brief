import Foundation

/// Turns the shared feed into one person's brief, entirely on the phone: their topics, enabled
/// sources, muted words and keyword boosts. Mirrors `list_brief` in briefing/summarize.py.
enum BriefBuilder {
    static let windowHours: Double = 24
    static let boostWeight = 3.0
    static let topCount = 5

    /// - Parameters:
    ///   - windowHours: hours of news to include, 24 normally; more (up to the feed's own window)
    ///     to catch someone up after a long absence.
    ///
    /// The window ends at the feed's build time, not the phone's clock: while the server runs late
    /// or the phone is offline with an old cache, stories shouldn't age out with nothing to replace
    /// them. With a fresh feed the two are minutes apart.
    static func build(feed: SharedFeed, settings: UserSettings, now: Date = .now,
                      timeZone: TimeZone = .current, windowHours: Double = BriefBuilder.windowHours) -> Brief {
        let window = clampedWindow(windowHours, feed: feed)
        let since = min(now, feed.generatedAt).addingTimeInterval(-window * 3600)
        let muted = TermMatcher(settings.mutedWords)
        let boosts = TermMatcher(settings.boosts)
        let wantsDeals = settings.categories.contains("Deals")

        var scored: [(story: Story, isDeal: Bool)] = []
        for s in feed.stories where s.published >= since {
            let sources = s.sources.filter { settings.isSourceEnabled($0.key) }
            guard !sources.isEmpty else { continue }
            let isDeal = s.label == ReliabilityLabel.deal.rawValue
            if isDeal ? !wantsDeals : !settings.categories.contains(s.category) { continue }
            let text = ([s.title] + sources.map(\.title)).joined(separator: " ")
            if muted.matches(text) { continue }
            let boost = Double(boosts.matchCount(in: text)) * boostWeight
            scored.append((story(s, sources: sources, isDeal: isDeal, score: s.score + boost), isDeal))
        }
        // Stable, so equal scores keep the feed's order.
        scored = scored.enumerated().sorted { l, r in
            let a = l.element.story.score ?? 0, b = r.element.story.score ?? 0
            return a != b ? a > b : l.offset < r.offset
        }.map(\.element)

        let top = scored.filter { !$0.isDeal }.prefix(topCount).map { $0.story }
        let topIDs = Set(top.map(\.id))
        let rest = scored.map { $0.story }.filter { !topIDs.contains($0.id) }
        let sections = settings.categories.map { name in
            BriefSection(name: name, stories: rest.filter { $0.category == name })
        }

        let count = top.count + sections.reduce(0) { $0 + $1.stories.count }
        // Only sources in topics they follow: someone who skipped Japan shouldn't see Japanese
        // outlets in the source count or in "not responding" warnings.
        let enabledSources = feed.sources.filter {
            settings.isSourceEnabled($0.key) && settings.categories.contains($0.category)
        }
        let problems = enabledSources.filter { $0.status != "ok" }.map(\.title)
        let hours = Int(window.rounded(.up))

        return Brief(
            date: Brief.day(of: now, timeZone: timeZone),
            generatedAt: feed.generatedAt,
            headline: headline(count: count, sources: enabledSources.count, hours: hours,
                               followsNothing: settings.categories.isEmpty),
            top: top,
            sections: sections,
            sourceProblems: problems,
            sourceCount: enabledSources.count,
            windowHours: hours
        )
    }

    /// Every topic, followed or not, with the reader's sources, muted words and boosts. Backs
    /// browsing an unfollowed topic and searching "All topics".
    static func allTopics(feed: SharedFeed, settings: UserSettings, now: Date = .now,
                          timeZone: TimeZone = .current, windowHours: Double = BriefBuilder.windowHours) -> Brief {
        var everything = settings
        everything.categories = settings.categories + settings.unfollowedCategories
        return build(feed: feed, settings: everything, now: now, timeZone: timeZone, windowHours: windowHours)
    }

    /// Every story of one topic in hot order, whether or not the reader follows it.
    static func browse(feed: SharedFeed, settings: UserSettings, topic: String, now: Date = .now,
                       windowHours: Double = BriefBuilder.windowHours) -> [Story] {
        var one = settings
        one.categories = [topic]
        return build(feed: feed, settings: one, now: now, windowHours: windowHours).stories(inTopic: topic)
    }

    /// A feed story as the reader would see it, ignoring their topics and muted words: used to
    /// open a tapped alert even when the story isn't in their brief. Sources they turned off are
    /// left out unless that would leave none.
    static func story(from s: FeedStory, settings: UserSettings) -> Story {
        let enabled = s.sources.filter { settings.isSourceEnabled($0.key) }
        let isDeal = s.label == ReliabilityLabel.deal.rawValue
        return story(s, sources: enabled.isEmpty ? s.sources : enabled, isDeal: isDeal, score: s.score)
    }

    /// The catch-up window: 24 h, or back to the reader's previous visit when that was longer
    /// ago, capped at the hours the feed holds.
    static func catchUpHours(lastVisit: Date?, feed: SharedFeed, now: Date = .now) -> Double {
        guard let lastVisit else { return windowHours }
        let gap = min(now, feed.generatedAt).timeIntervalSince(lastVisit) / 3600
        return clampedWindow(gap.rounded(.up), feed: feed)
    }

    private static func clampedWindow(_ hours: Double, feed: SharedFeed) -> Double {
        min(max(hours, windowHours), max(Double(feed.windowHours), windowHours))
    }

    private static func story(_ s: FeedStory, sources: [FeedSource], isDeal: Bool, score: Double) -> Story {
        Story(
            id: s.id,
            title: s.title,
            summary: s.summary,
            importance: min(5, max(1, Set(sources.map(\.outlet)).count)),
            label: s.label,
            category: isDeal ? "Deals" : s.category,
            published: s.published,
            outletCount: Set(sources.map(\.outlet)).count,
            sources: sources.map {
                Source(outlet: $0.outlet, title: $0.title, url: $0.url, official: $0.official,
                       translatedFrom: $0.translatedFrom, originalTitle: $0.originalTitle,
                       published: $0.published, key: $0.key)
            },
            aiSummary: s.aiSummary,
            opinion: s.opinion,
            score: score
        )
    }

    private static func headline(count: Int, sources: Int, hours: Int, followsNothing: Bool) -> String {
        if followsNothing { return "You're not following any topics." }
        if count == 0 { return "Nothing new yet. Check back soon." }
        let stories = "\(count) \(count == 1 ? "story" : "stories")"
        if hours > Int(windowHours) { return "Catching you up: \(stories) from the last \(hours) hours" }
        return "\(stories) from \(sources) \(sources == 1 ? "source" : "sources")"
    }
}

/// Matches muted and boosted words as whole words, so muting "ice" doesn't hide "police" and
/// boosting "AI" doesn't promote everything "said". Case-insensitive; a trailing "s" or "es" is
/// allowed so "game" still matches "games"; multi-word terms ("call of duty") and symbols ("c++")
/// work too. Same rule as `termMatches` in server/src/matching.js.
struct TermMatcher {
    private let patterns: [NSRegularExpression]

    init(_ terms: [String]) {
        patterns = terms.compactMap { term in
            let words = term.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard !words.isEmpty else { return nil }
            let body = words.joined(separator: "\\s+")
            return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(body)(?:s|es)?(?![\\p{L}\\p{N}])",
                                            options: [.caseInsensitive])
        }
    }

    var isEmpty: Bool { patterns.isEmpty }

    func matches(_ text: String) -> Bool {
        patterns.contains { Self.hit($0, text) }
    }

    /// How many of the terms appear (each counts once).
    func matchCount(in text: String) -> Int {
        patterns.reduce(0) { $0 + (Self.hit($1, text) ? 1 : 0) }
    }

    private static func hit(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
