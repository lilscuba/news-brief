import XCTest
@testable import PersonalFeed

/// Search, "More on this story" and the Latest time groups, against the fixture.
final class SearchAndRelatedTests: XCTestCase {
    private var feed: SharedFeed!
    private var now: Date!
    private var everything: Brief!

    override func setUpWithError() throws {
        feed = try Fixture.feed()
        now = feed.generatedAt
        everything = BriefBuilder.allTopics(feed: feed, settings: .default, now: now)
    }

    // MARK: Search

    func testSearchMatchesEveryWordAndPutsHeadlineMatchesFirst() throws {
        let stories = everything.allStoriesByScore
        let results = StorySearch.filter(stories, query: "anthropic")
        XCTAssertFalse(results.isEmpty)
        func inTitle(_ s: Story) -> Bool { s.title.localizedStandardContains("anthropic") }
        let firstElsewhere = results.firstIndex { !inTitle($0) } ?? results.count
        XCTAssertTrue(results[..<firstElsewhere].allSatisfy(inTitle))
        XCTAssertFalse(results[firstElsewhere...].contains(where: inTitle), "headline matches come first")
        // Within the headline matches, hot order is kept.
        let order = stories.map(\.id)
        let titleHits = results[..<firstElsewhere].map { order.firstIndex(of: $0.id)! }
        XCTAssertEqual(titleHits, titleHits.sorted())

        let narrower = StorySearch.filter(stories, query: "  Anthropic   IPO ")
        XCTAssertFalse(narrower.isEmpty)
        XCTAssertLessThan(narrower.count, results.count, "every word must match")
        XCTAssertTrue(narrower.allSatisfy { $0.title.localizedStandardContains("ipo") || $0.summary.localizedStandardContains("ipo")
            || $0.sources.contains { $0.title.localizedStandardContains("ipo") } })

        XCTAssertTrue(StorySearch.filter(stories, query: "   ").isEmpty)
        XCTAssertTrue(StorySearch.filter(stories, query: "zzqxv").isEmpty)
    }

    func testSearchFindsOutletsSummariesAndOriginalHeadlines() throws {
        let outlet = try XCTUnwrap(everything.allStories.first?.sources.first?.outlet)
        let byOutlet = Set(StorySearch.filter(everything.allStories, query: outlet).map(\.id))
        let fromOutlet = everything.allStories.filter { $0.sources.contains { $0.outlet == outlet } }.map(\.id)
        XCTAssertFalse(fromOutlet.isEmpty)
        XCTAssertTrue(Set(fromOutlet).isSubset(of: byOutlet), "every story from \(outlet) is found")

        let translated = Story.make(id: "de", title: "Inflation falls in Germany", category: "Europe", published: now,
                                    summary: "Prices rose more slowly in Zwickau.",
                                    sources: [Source(outlet: "Tagesschau (Germany)", title: "Inflation falls in Germany",
                                                     url: URL(string: "https://example.com/de")!, official: false,
                                                     translatedFrom: "de", originalTitle: "Inflation sinkt deutlich")])
        let pool = [translated] + everything.allStories
        XCTAssertEqual(StorySearch.filter(pool, query: "sinkt").map(\.id), ["de"], "original-language headline")
        XCTAssertEqual(StorySearch.filter(pool, query: "tagesschau").map(\.id), ["de"], "outlet")
        XCTAssertEqual(StorySearch.filter(pool, query: "ZWICKAU").map(\.id), ["de"], "summary, any case")
        XCTAssertEqual(StorySearch.filter(pool + [translated], query: "sinkt").count, 1, "no duplicates")
    }

    // MARK: Related

    func testRelatedStoriesFindTheSameEventAcrossTopics() {
        let t = now!
        let world = Story.make(id: "w", title: "Brazil's Bolsonaro and Lula head to a runoff", category: "World", published: t)
        let us = Story.make(id: "u", title: "Bolsonaro, Lula advance to Brazil runoff", category: "US", published: t)
        let europe = Story.make(id: "e", title: "Brazil election: Bolsonaro leads Lula before runoff", category: "Europe", published: t)
        let deal = Story.make(id: "d", title: "Bolsonaro runoff Brazil t-shirt deal", category: "Deals", published: t, label: "DEAL")
        let unrelated = Story.make(id: "x", title: "Brazil beats Argentina in World Cup qualifier", category: "World", published: t)
        let corpus = [world, us, europe, deal, unrelated] + everything.allStories

        let related = RelatedStories.find(for: world, in: corpus)
        XCTAssertEqual(Set(related.map(\.id)), ["u", "e"], "cross-topic, no deals, not itself")
        XCTAssertTrue(RelatedStories.find(for: deal, in: corpus).isEmpty, "deals have no related stories")
        XCTAssertFalse(related.contains { $0.id == "x" }, "one shared word isn't enough")
    }

    func testRelatedStoriesOnTheFixtureAreStrictAndCapped() {
        let index = RelatedStories(stories: everything.allStories)
        var found = 0
        for story in everything.allStories {
            let related = index.related(to: story)
            XCTAssertLessThanOrEqual(related.count, 4)
            if !related.isEmpty { found += 1 }
            let mine = RelatedStories.words(in: story.title)
            for other in related {
                XCTAssertNotEqual(other.id, story.id)
                XCTAssertNotEqual(other.label, "DEAL")
                XCTAssertGreaterThanOrEqual(mine.intersection(RelatedStories.words(in: other.title)).count, 2)
            }
        }
        XCTAssertLessThan(found, everything.allStories.count / 2, "most stories have nothing related")
    }

    func testHeadlineWordsIgnoreStopWordsAndPossessives() {
        XCTAssertEqual(RelatedStories.words(in: "Brazil's Bolsonaro says he will win the 2026 runoff"),
                       ["brazil", "bolsonaro", "win", "runoff"])
    }

    // MARK: Latest time groups

    func testLatestGroupsByTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        // 2026-10-05 15:00 in Toronto.
        let t = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 15)))
        func story(_ id: String, _ minutesAgo: Double) -> Story {
            Story.make(id: id, title: id, published: t.addingTimeInterval(-minutesAgo * 60))
        }
        let stories = StorySort.latest.apply([
            story("a", 10), story("b", 59), story("c", 61), story("d", 14 * 60),   // 01:00 today
            story("e", 15 * 60 + 1),  // 23:59 yesterday
            story("f", 30 * 60), story("g", 50 * 60), story("h", 3 * 24 * 60),
        ])
        let buckets = StorySort.buckets(stories, now: t, calendar: calendar)
        XCTAssertEqual(buckets.map(\.title), ["Last hour", "Earlier today", "Yesterday", "Older"])
        XCTAssertEqual(buckets.map { $0.stories.map(\.id) }, [["a", "b"], ["c", "d"], ["e", "f"], ["g", "h"]])

        let recentOnly = StorySort.buckets([story("a", 5), story("x", 30)], now: t, calendar: calendar)
        XCTAssertEqual(recentOnly.map(\.title), ["Last hour"], "empty groups are left out")
        XCTAssertTrue(StorySort.buckets([], now: t, calendar: calendar).isEmpty)
    }
}
