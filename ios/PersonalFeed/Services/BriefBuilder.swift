import Foundation

/// Turns the shared feed into one person's brief, entirely on the phone: their topics, enabled
/// sources, muted words and keyword boosts. Mirrors `list_brief` in briefing/summarize.py.
enum BriefBuilder {
    static let windowHours: Double = 24
    static let boostWeight = 3.0
    static let topCount = 5

    static func build(feed: SharedFeed, settings: UserSettings, now: Date = .now,
                      timeZone: TimeZone = .current) -> Brief {
        let since = now.addingTimeInterval(-windowHours * 3600)
        let muted = settings.mutedWords.map { $0.lowercased() }
        let boosts = settings.boosts.map { $0.lowercased() }
        let wantsDeals = settings.categories.contains("Deals")

        var scored: [(story: Story, score: Double, isDeal: Bool)] = []
        for s in feed.stories where s.published >= since {
            let sources = s.sources.filter { settings.isSourceEnabled($0.key) }
            guard !sources.isEmpty else { continue }
            let isDeal = s.label == "DEAL"
            if isDeal ? !wantsDeals : !settings.categories.contains(s.category) { continue }
            let text = ([s.title] + sources.map(\.title)).joined(separator: " ").lowercased()
            if muted.contains(where: { text.contains($0) }) { continue }
            let boost = Double(boosts.filter { text.contains($0) }.count) * boostWeight
            let outlets = Set(sources.map(\.outlet)).count
            let story = Story(
                id: s.id,
                title: s.title,
                summary: s.summary,
                importance: min(5, max(1, outlets)),
                label: s.label,
                category: isDeal ? "Deals" : s.category,
                published: s.published,
                outletCount: outlets,
                sources: sources.map {
                    Source(outlet: $0.outlet, title: $0.title, url: $0.url, official: $0.official,
                           translatedFrom: $0.translatedFrom, originalTitle: $0.originalTitle)
                },
                aiSummary: s.aiSummary
            )
            scored.append((story, s.score + boost, isDeal))
        }
        scored.sort { $0.score > $1.score }

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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        let date = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)

        return Brief(
            date: date,
            generatedAt: feed.generatedAt,
            headline: count == 0
                ? "Nothing new yet. Check back soon."
                : "\(count) \(count == 1 ? "story" : "stories") from \(enabledSources.count) sources",
            top: top,
            sections: sections,
            sourceProblems: problems
        )
    }
}
