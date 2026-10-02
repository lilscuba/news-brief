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

    func testTopicsSourcesAndMutes() {
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

        let word = feed.stories[0].title.split(separator: " ").max { $0.count < $1.count }.map(String.init)!
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

    func testSettingsJSONMatchesServerShape() throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(UserSettings.default)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["version", "categories", "disabledSources", "mutedWords", "boosts", "alerts", "brief"])
        let alerts = json["alerts"] as! [String: Any]
        XCTAssertEqual(Set(alerts.keys), ["official", "trusted", "corroborated", "defaultWatchlist", "keywords", "maxPerDay"])
    }
}
