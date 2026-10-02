import XCTest
@testable import PersonalFeed

/// shared-feed-fixture.json is real output of `python -m briefing ingest --dry-run`
/// (server/dev/feed.json). If the backend schema changes, copy a fresh one over and rerun.
final class BriefBuilderTests: XCTestCase {
    private var feed: SharedFeed!
    private var now: Date!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "shared-feed-fixture", withExtension: "json"))
        feed = try JSONDecoder.api.decode(SharedFeed.self, from: Data(contentsOf: url))
        now = feed.generatedAt
    }

    func testDecodesSharedFeed() {
        XCTAssertEqual(feed.version, 1)
        XCTAssertFalse(feed.stories.isEmpty)
        XCTAssertFalse(feed.sources.isEmpty)
        XCTAssertFalse(feed.watchlist.isEmpty)
    }

    func testDefaultSettingsBuildAFullBrief() {
        let brief = BriefBuilder.build(feed: feed, settings: .default, now: now)
        XCTAssertEqual(brief.top.count, 5)
        XCTAssertEqual(brief.sections.map(\.name), ["AI", "Tech", "Gaming", "Deals"])
        XCTAssertFalse(brief.top.contains { $0.label == "DEAL" }, "deals never go on top")
        XCTAssertTrue(brief.sections.last!.stories.allSatisfy { $0.label == "DEAL" })
        let ids = brief.allStories.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "no story appears twice")
        for story in brief.allStories {
            XCTAssertFalse(story.sources.isEmpty)
            XCTAssert((1...5).contains(story.importance))
        }
    }

    func testTopicsSourcesAndMutes() throws {
        var s = UserSettings.default
        s.categories = ["Gaming"]
        let gaming = BriefBuilder.build(feed: feed, settings: s, now: now)
        XCTAssertEqual(gaming.sections.map(\.name), ["Gaming"])
        XCTAssertTrue(gaming.allStories.allSatisfy { $0.category == "Gaming" })

        let firstSource = feed.stories[0].sources[0]
        s = .default
        s.disabledSources = [firstSource.key]
        let without = BriefBuilder.build(feed: feed, settings: s, now: now)
        XCTAssertFalse(without.allStories.flatMap(\.sources).contains { $0.outlet == firstSource.outlet })

        let words: [Substring] = feed.stories[0].title.split(separator: " ")
        let word = String(try XCTUnwrap(words.max { $0.count < $1.count }))
        s = .default
        s.mutedWords = [word]
        let muted = BriefBuilder.build(feed: feed, settings: s, now: now)
        XCTAssertFalse(muted.allStories.contains { $0.title.localizedCaseInsensitiveContains(word) })
    }

    func testBoostsMoveStoriesUp() throws {
        let base = BriefBuilder.build(feed: feed, settings: .default, now: now)
        let target = try XCTUnwrap(base.sections.flatMap(\.stories).last { $0.label != "DEAL" })
        var s = UserSettings.default
        s.boosts = [String(target.title.prefix(40)).lowercased()]
        let boosted = BriefBuilder.build(feed: feed, settings: s, now: now)
        let before = base.allStories.firstIndex { $0.id == target.id }!
        let after = boosted.allStories.firstIndex { $0.id == target.id }!
        XCTAssertLessThanOrEqual(after, before)
    }

    func testRegionTopicsAreOptInAndKeepDisplayOrder() {
        XCTAssertEqual(UserSettings.default.categories, ["AI", "Tech", "Gaming", "Deals"])
        var s = UserSettings.default
        s.setCategory("Korea", enabled: true)
        s.setCategory("World", enabled: true)
        XCTAssertEqual(s.categories, ["AI", "Tech", "Gaming", "World", "Korea", "Deals"])
    }

    func testRegionStoriesAndSourceWarningsOnlyShowForFollowedTopics() {
        let story = FeedStory(
            id: "jp1", title: "Tokyo inflation hits 2.7% in September", summary: "", label: "REPORTED",
            category: "Japan", score: 3, official: false, trusted: false, outletCount: 1, published: now,
            sources: [FeedSource(key: "japantimes", outlet: "The Japan Times", title: "Tokyo inflation hits 2.7%",
                                 url: URL(string: "https://example.com/jt")!, official: false, published: now)])
        let japanTimes = SourceInfo(key: "japantimes", title: "The Japan Times", category: "Japan",
                                    official: false, trusted: false, mirror: false, status: "error", latest: nil)
        let withJapan = SharedFeed(version: 1, generatedAt: feed.generatedAt, windowHours: feed.windowHours,
                                   sections: feed.sections, sources: feed.sources + [japanTimes],
                                   watchlist: feed.watchlist, stories: feed.stories + [story])

        let skipped = BriefBuilder.build(feed: withJapan, settings: .default, now: now)
        XCTAssertFalse(skipped.sections.contains { $0.name == "Japan" })
        XCTAssertFalse(skipped.allStories.contains { $0.id == "jp1" })
        XCTAssertFalse(skipped.sourceProblems.contains("The Japan Times"))

        var s = UserSettings.default
        s.setCategory("Japan", enabled: true)
        let followed = BriefBuilder.build(feed: withJapan, settings: s, now: now)
        XCTAssertEqual(followed.sections.first { $0.name == "Japan" }?.stories.map(\.id), ["jp1"])
        XCTAssertTrue(followed.sourceProblems.contains("The Japan Times"))
    }

    func testTranslatedHeadlinesKeepTheirOriginalAndOldFeedsStillDecode() throws {
        let json = """
        {"key":"tagesschau","outlet":"Tagesschau (Germany)","title":"Inflation falls","url":"https://example.com/a",
         "official":false,"published":"2026-10-01T12:00:00Z","translatedFrom":"de","originalTitle":"Inflation sinkt"}
        """
        let translated = try JSONDecoder.api.decode(FeedSource.self, from: Data(json.utf8))
        XCTAssertEqual(translated.translatedFrom, "de")
        XCTAssertEqual(translated.originalTitle, "Inflation sinkt")
        XCTAssertNil(feed.stories[0].sources[0].translatedFrom, "feeds without the new fields still decode")

        let story = FeedStory(id: "de1", title: "Inflation falls", summary: "", label: "REPORTED", category: "Europe",
                              score: 3, official: false, trusted: false, outletCount: 1, published: now, sources: [translated])
        let withGerman = SharedFeed(version: 1, generatedAt: feed.generatedAt, windowHours: feed.windowHours,
                                    sections: feed.sections, sources: feed.sources, watchlist: feed.watchlist,
                                    stories: feed.stories + [story])
        var s = UserSettings.default
        s.setCategory("Europe", enabled: true)
        let europe = BriefBuilder.build(feed: withGerman, settings: s, now: now).allStories.first { $0.id == "de1" }
        XCTAssertEqual(europe?.isTranslated, true)
        XCTAssertEqual(europe?.sources.first?.originalTitle, "Inflation sinkt")
        XCTAssertFalse(try XCTUnwrap(feed.stories.first).sources.isEmpty)
    }

    func testAISummaryFlagReachesTheBriefAndOldFeedsStillDecode() throws {
        XCTAssertNil(feed.stories[0].aiSummary, "feeds without the field still decode")
        var summarized = feed.stories[0]
        summarized.aiSummary = true
        let patched = SharedFeed(version: 1, generatedAt: feed.generatedAt, windowHours: feed.windowHours,
                                 sections: feed.sections, sources: feed.sources, watchlist: feed.watchlist,
                                 stories: [summarized] + feed.stories.dropFirst())
        let brief = BriefBuilder.build(feed: patched, settings: .default, now: now)
        let flagged = brief.allStories.filter { $0.aiSummary == true }.map(\.id)
        XCTAssertLessThanOrEqual(flagged.count, 1)
        if let id = flagged.first { XCTAssertEqual(id, summarized.id) }

        let json = #"{"id":"a","title":"t","summary":"s","label":"REPORTED","category":"Tech","score":1,"official":false,"trusted":false,"outletCount":1,"published":"2026-10-01T12:00:00Z","sources":[],"aiSummary":true}"#
        XCTAssertEqual(try JSONDecoder.api.decode(FeedStory.self, from: Data(json.utf8)).aiSummary, true)
    }

    func testLatestSortsNewestFirstAndHotKeepsTheFeedOrder() {
        func story(_ id: String, minutesAgo: Double) -> Story {
            Story(id: id, title: id, summary: "", importance: 1, label: nil, category: "Tech",
                  published: now.addingTimeInterval(-minutesAgo * 60), outletCount: 1, sources: [])
        }
        // Hot order: a (oldest), b, c and d share a time, e (newest).
        let hot = [story("a", minutesAgo: 300), story("b", minutesAgo: 60), story("c", minutesAgo: 60),
                   story("d", minutesAgo: 60), story("e", minutesAgo: 5)]
        XCTAssertEqual(StorySort.hot.apply(hot).map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(StorySort.latest.apply(hot).map(\.id), ["e", "b", "c", "d", "a"], "ties keep hot order")
        XCTAssertEqual(StorySort.allCases, [.hot, .latest], "hot topics is first, so the default")
        XCTAssertEqual(StorySort(rawValue: "latest"), .latest)
    }

    func testSettingsJSONMatchesServerShape() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(UserSettings.default)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["version", "categories", "disabledSources", "mutedWords", "boosts", "alerts", "brief"])
        let alerts = json["alerts"] as! [String: Any]
        XCTAssertEqual(Set(alerts.keys), ["official", "trusted", "corroborated", "defaultWatchlist", "keywords", "maxPerDay"])
    }
}
