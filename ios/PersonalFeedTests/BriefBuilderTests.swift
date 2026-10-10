import SwiftUI
import XCTest
@testable import PersonalFeed

/// shared-feed-fixture.json is real output of `python -m briefing ingest --dry-run`
/// (server/dev/feed.json). If the backend schema changes, copy a fresh one over and rerun.
final class BriefBuilderTests: XCTestCase {
    private var feed: SharedFeed!
    private var now: Date!

    override func setUpWithError() throws {
        feed = try Fixture.feed()
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
        let ids = brief.top.map(\.id) + brief.sections.flatMap { $0.stories.map(\.id) }
        XCTAssertEqual(ids.count, Set(ids).count, "no story appears twice on Today")
        XCTAssertEqual(brief.storyCount, ids.count)
        XCTAssertTrue(brief.headline.hasPrefix("\(ids.count) stories from "))
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
        let section = try XCTUnwrap(base.sections.first { $0.name == "Tech" })
        let target = try XCTUnwrap(section.stories.last)
        var s = UserSettings.default
        // A whole headline: boosts match whole words, so a prefix cut mid-word wouldn't match.
        s.boosts = [target.title]
        let boosted = BriefBuilder.build(feed: feed, settings: s, now: now)
        let after = try XCTUnwrap(boosted.allStories.first { $0.id == target.id })
        XCTAssertEqual(after.score ?? 0, (target.score ?? 0) + BriefBuilder.boostWeight, accuracy: 0.001)
        let before = section.stories.firstIndex { $0.id == target.id }!
        let now = boosted.stories(inTopic: "Tech").firstIndex { $0.id == target.id }!
        XCTAssertLessThan(now, before)
    }

    func testFollowingATopicAppendsItInTheReadersOrder() {
        XCTAssertEqual(UserSettings.default.categories, ["AI", "Tech", "Gaming", "Deals"])
        var s = UserSettings.default
        s.setCategory("Korea", enabled: true)
        s.setCategory("World", enabled: true)
        s.setCategory("World", enabled: true)
        XCTAssertEqual(s.categories, ["AI", "Tech", "Gaming", "Deals", "Korea", "World"])
        s.setCategory("Tech", enabled: false)
        XCTAssertEqual(s.categories, ["AI", "Gaming", "Deals", "Korea", "World"])
        XCTAssertEqual(s.unfollowedCategories, ["Tech", "US", "Europe", "Japan"])
        // Sections follow the reader's order.
        let brief = BriefBuilder.build(feed: feed, settings: s, now: now)
        XCTAssertEqual(brief.sections.map(\.name), s.categories)
    }

    func testMovingTopicsMatchesSwiftUIsOnMove() {
        let start = ["AI", "Tech", "Gaming", "Deals"]
        for (from, to) in [(IndexSet([0]), 3), (IndexSet([3]), 0), (IndexSet([1, 2]), 4), (IndexSet([0, 3]), 2), (IndexSet([2]), 2)] {
            var s = UserSettings.default
            s.categories = start
            s.moveCategories(fromOffsets: from, toOffset: to)
            var expected = start
            expected.move(fromOffsets: from, toOffset: to)
            XCTAssertEqual(s.categories, expected, "move \(Array(from)) to \(to)")
        }
    }

    func testOnlyBriefSettingsNeedARebuild() {
        var s = UserSettings.default
        let key = s.briefKey
        s.alerts.maxPerDay = 9
        s.alerts.keywords = ["zelda"]
        s.brief.hour = 6
        XCTAssertEqual(s.briefKey, key, "alert and morning-brief edits don't change the brief")
        s.mutedWords = ["crypto"]
        XCTAssertNotEqual(s.briefKey, key)
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
        XCTAssertEqual(followed.stories(inTopic: "Japan").map(\.id), ["jp1"])
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
        XCTAssertEqual(europe?.leadOutlet, "Tagesschau")
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

    func testOpinionStaleAndPerSourceFieldsReachTheBrief() throws {
        XCTAssertNil(feed.stories[0].opinion, "feeds without the field still decode")
        XCTAssertNil(feed.sources[0].stale)
        let json = #"{"key":"k","title":"T","category":"Tech","official":false,"trusted":false,"mirror":false,"status":"ok","latest":null,"stale":true}"#
        XCTAssertTrue(try JSONDecoder.api.decode(SourceInfo.self, from: Data(json.utf8)).isStale)

        var opinion = FeedStory.make(id: "op", title: "Why the new MacBook is a mistake", score: 99,
                                     published: now.addingTimeInterval(-600), outlet: "The Verge", key: "verge")
        opinion.opinion = true
        let brief = BriefBuilder.build(feed: feed.later(by: 0, adding: [opinion]), settings: .default, now: now)
        let story = try XCTUnwrap(brief.allStories.first { $0.id == "op" })
        XCTAssertTrue(story.isOpinion)
        XCTAssertEqual(story.sources.first?.key, "verge")
        XCTAssertEqual(story.sources.first?.published, now.addingTimeInterval(-600))
        XCTAssertFalse(try XCTUnwrap(brief.allStories.first { $0.id != "op" }).isOpinion)
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

    // MARK: Topic pages

    func testTopicPagesIncludeTheirTopStoriesInHotOrder() {
        var s = UserSettings.default
        s.categories = UserSettings.allCategories
        for settings in [UserSettings.default, s] {
            let brief = BriefBuilder.build(feed: feed, settings: settings, now: now)
            var covered = Set<String>()
            for section in brief.sections {
                let page = brief.stories(inTopic: section.name)
                let promoted = brief.top.filter { $0.category == section.name }
                XCTAssertEqual(Array(page.prefix(promoted.count)).map(\.id), promoted.map(\.id),
                               "\(section.name) leads with its Top stories")
                XCTAssertEqual(page.count, promoted.count + section.stories.count)
                let scores = page.compactMap(\.score)
                XCTAssertEqual(scores, scores.sorted(by: >), "\(section.name) stays in hot order")
                covered.formUnion(page.map(\.id))
            }
            XCTAssertEqual(covered, Set(brief.allStories.map(\.id)), "every story is on its topic's page")
        }
    }

    func testATopicWhoseStoriesAllMadeTopStoriesIsStillListed() {
        let hit = FeedStory.make(id: "ai1", title: "OpenAI ships a new reasoning model", category: "AI",
                                 score: 999, published: now)
        let thin = SharedFeed(version: 1, generatedAt: now, windowHours: 48, sections: feed.sections,
                              sources: feed.sources, watchlist: [],
                              stories: [hit] + feed.stories.filter { $0.category != "AI" })
        let brief = BriefBuilder.build(feed: thin, settings: .default, now: now)
        XCTAssertTrue(brief.sections.first { $0.name == "AI" }!.stories.isEmpty, "Today doesn't repeat it")
        XCTAssertEqual(brief.stories(inTopic: "AI").map(\.id), ["ai1"])
        XCTAssertTrue(brief.topicsWithStories.contains("AI"))
        XCTAssertFalse(brief.quietTopics.contains("AI"))
    }

    // MARK: Muted and boosted words

    func testTermsMatchWholeWords() {
        let ice = TermMatcher(["ice"])
        XCTAssertTrue(ice.matches("ICE raids in Chicago"))
        XCTAssertTrue(ice.matches("Protest outside ICE's office"))
        for text in ["Police arrest suspect", "Prices rise", "Microsoft service outage", "Voice chat"] {
            XCTAssertFalse(ice.matches(text), text)
        }
        let ai = TermMatcher(["AI"])
        XCTAssertTrue(ai.matches("Google's AI-powered search"))
        XCTAssertTrue(ai.matches("New ai model"))
        for text in ["He said again", "Brazil votes", "Taiwan chips"] { XCTAssertFalse(ai.matches(text), text) }

        let game = TermMatcher(["game"])
        XCTAssertTrue(game.matches("Best games of 2026"), "plural still matches")
        XCTAssertTrue(game.matches("Game of the year"))
        XCTAssertFalse(game.matches("New gameplay trailer"))

        let cpp = TermMatcher(["c++"])
        XCTAssertTrue(cpp.matches("What's new in C++26? C++ gets reflection"))
        XCTAssertTrue(cpp.matches("Learning C++"))
        XCTAssertFalse(cpp.matches("C is fine"))

        let cod = TermMatcher(["call of duty"])
        XCTAssertTrue(cod.matches("Call of Duty: Black Ops 7 review"))
        XCTAssertTrue(cod.matches("call  of\tduty leaks"), "any spacing")
        XCTAssertFalse(cod.matches("A call for duty-free shopping"))

        let f1 = TermMatcher(["F1"])
        XCTAssertTrue(f1.matches("F1 race moved"))
        XCTAssertFalse(f1.matches("F15 jets"))

        XCTAssertEqual(TermMatcher(["apple", "ai", "nintendo", ""]).matchCount(in: "Apple AI and Apple again"), 2)
        XCTAssertTrue(TermMatcher(["", "  "]).isEmpty)
    }

    func testMutingAShortWordOnlyHidesThatWord() throws {
        let police = FeedStory.make(id: "p", title: "Police arrest drug smugglers at the border", score: 40, published: now)
        let ice = FeedStory.make(id: "i", title: "ICE expands detention centers", score: 40, published: now)
        let games = FeedStory.make(id: "g", title: "The best games of the month", category: "Gaming", score: 40, published: now)
        let patched = feed.later(by: 0, adding: [police, ice, games])
        var s = UserSettings.default
        s.mutedWords = ["ice", "game"]
        let ids = Set(BriefBuilder.build(feed: patched, settings: s, now: now).allStories.map(\.id))
        XCTAssertTrue(ids.contains("p"), "'ice' doesn't hide 'police'")
        XCTAssertFalse(ids.contains("i"))
        XCTAssertFalse(ids.contains("g"), "'game' hides 'games'")
    }

    // MARK: Window

    func testTheWindowEndsAtTheFeedsTimeNotThePhonesClock() {
        let fresh = BriefBuilder.build(feed: feed, settings: .default, now: now)
        let late = BriefBuilder.build(feed: feed, settings: .default, now: now.addingTimeInterval(6 * 3600))
        XCTAssertEqual(late.allStories.map(\.id), fresh.allStories.map(\.id), "a late server doesn't shrink the brief")
        let stale = BriefBuilder.build(feed: feed, settings: .default, now: now.addingTimeInterval(30 * 3600))
        XCTAssertFalse(stale.allStories.isEmpty, "an old cache still shows its news")
        XCTAssertEqual(stale.storyCount, fresh.storyCount)
        XCTAssertEqual(fresh.windowHours, 24)
    }

    func testCatchingUpAfterALongAbsenceWidensTheWindow() throws {
        let day = BriefBuilder.build(feed: feed, settings: .default, now: now)
        let hours = BriefBuilder.catchUpHours(lastVisit: now.addingTimeInterval(-30 * 3600), feed: feed, now: now)
        XCTAssertEqual(hours, 30)
        let catchUp = BriefBuilder.build(feed: feed, settings: .default, now: now, windowHours: hours)
        XCTAssertGreaterThan(catchUp.storyCount, day.storyCount)
        let oldest = try XCTUnwrap(catchUp.allStories.map(\.published).min())
        XCTAssertLessThan(oldest, now.addingTimeInterval(-24 * 3600), "includes stories 24-30 h old")
        XCTAssertGreaterThanOrEqual(oldest, now.addingTimeInterval(-30 * 3600))
        XCTAssertEqual(catchUp.windowHours, 30)
        XCTAssertTrue(catchUp.headline.contains("last 30 hours"), catchUp.headline)

        XCTAssertEqual(BriefBuilder.catchUpHours(lastVisit: nil, feed: feed, now: now), 24)
        XCTAssertEqual(BriefBuilder.catchUpHours(lastVisit: now.addingTimeInterval(-2 * 3600), feed: feed, now: now), 24)
        XCTAssertEqual(BriefBuilder.catchUpHours(lastVisit: now.addingTimeInterval(-200 * 3600), feed: feed, now: now),
                       Double(feed.windowHours), "never more than the feed holds")
        XCTAssertEqual(BriefBuilder.build(feed: feed, settings: .default, now: now, windowHours: 500).windowHours,
                       feed.windowHours)
    }

    func testFollowingNothingSaysSo() {
        var s = UserSettings.default
        s.categories = []
        let brief = BriefBuilder.build(feed: feed, settings: s, now: now)
        XCTAssertTrue(brief.allStories.isEmpty)
        XCTAssertEqual(brief.headline, "You're not following any topics.")
    }

    // MARK: Unfollowed topics and pushes

    func testUnfollowedTopicsCanBeBrowsed() throws {
        var s = UserSettings.default
        s.categories = ["AI"]
        s.mutedWords = ["nintendo"]
        let gaming = BriefBuilder.browse(feed: feed, settings: s, topic: "Gaming", now: now)
        XCTAssertFalse(gaming.isEmpty)
        XCTAssertTrue(gaming.allSatisfy { $0.category == "Gaming" })
        XCTAssertFalse(gaming.contains { TermMatcher(["nintendo"]).matches($0.title) }, "muted words still apply")

        let all = BriefBuilder.allTopics(feed: feed, settings: s, now: now)
        XCTAssertEqual(all.sections.map(\.name).first, "AI", "followed topics first")
        XCTAssertEqual(Set(all.sections.map(\.name)), Set(UserSettings.allCategories))
        XCTAssertEqual(Set(all.stories(inTopic: "Gaming").map(\.id)), Set(gaming.map(\.id)))
    }

    func testAPushedStoryResolvesEvenOutsideTheReadersTopics() throws {
        var s = UserSettings.default
        s.categories = ["AI"]
        let gaming = try XCTUnwrap(feed.stories.first { $0.category == "Gaming" && $0.label != "DEAL" })
        let story = BriefBuilder.story(from: gaming, settings: s)
        XCTAssertEqual(story.id, gaming.id)
        XCTAssertEqual(story.category, "Gaming")
        XCTAssertEqual(story.sources.map(\.url), gaming.sources.map(\.url))
        s.disabledSources = gaming.sources.map(\.key)
        XCTAssertFalse(BriefBuilder.story(from: gaming, settings: s).sources.isEmpty, "never left with no source")
    }

    // MARK: Story details

    func testStoryDetailsForRows() throws {
        let t0 = now!
        func source(_ outlet: String, _ minutesAgo: Double?) -> Source {
            Source(outlet: outlet, title: "t", url: URL(string: "https://example.com/\(outlet.hashValue)")!,
                   official: false, published: minutesAgo.map { t0.addingTimeInterval(-$0 * 60) })
        }
        XCTAssertEqual(Source.shortName("Hacker News (100+ points)"), "Hacker News")
        XCTAssertEqual(Source.shortName("The Wall Street Journal: U.S."), "The Wall Street Journal")
        XCTAssertEqual(Source.shortName("CNA: World (Singapore)"), "CNA")
        XCTAssertEqual(Source.shortName("HN: Claude/Anthropic"), "Hacker News")
        XCTAssertEqual(Source.shortName("The Verge"), "The Verge")

        let story = Story.make(id: "s", title: "Apple unveils an OLED MacBook Pro", published: t0,
                               sources: [source("The Verge", 5), source("BBC News: World", 300), source("The Verge", 60)])
        XCTAssertEqual(story.leadOutlet, "The Verge")
        XCTAssertEqual(story.outlets, ["The Verge", "BBC News"])
        XCTAssertEqual(story.firstReported, t0.addingTimeInterval(-300 * 60))
        XCTAssertEqual(Story.make(id: "o", title: "x", published: t0, sources: [source("A", nil)]).firstReported, t0,
                       "briefs saved before per-source times fall back to published")

        XCTAssertFalse(Story.make(id: "a", title: "Pi 1.0", published: t0, summary: "").hasUsefulSummary)
        XCTAssertFalse(Story.make(id: "b", title: "Pi 1.0 is out", published: t0, summary: "Pi 1.0 is out.").hasUsefulSummary)
        XCTAssertFalse(Story.make(id: "c", title: "Microsoft's Office chief is leaving",
                                  published: t0, summary: "Microsoft’s Office chief is leaving").hasUsefulSummary)
        XCTAssertTrue(Story.make(id: "d", title: "Pi 1.0 is out", published: t0,
                                 summary: "The release adds a package manager, a faster compiler and Windows support.").hasUsefulSummary)

        XCTAssertEqual(Story.make(id: "r", title: "x", published: t0, label: "RUMOR-UNVERIFIED").reliability, .unverifiedRumor)
        XCTAssertEqual(ReliabilityLabel.unverifiedRumor.displayName, "Unverified rumor")
        XCTAssertEqual(ReliabilityLabel.credibleRumor.displayName, "Credible rumor")
        XCTAssertEqual(ReliabilityLabel.confirmed.displayName, "Confirmed")
        XCTAssertEqual(ReliabilityLabel.deal.displayName, "Deal")
        XCTAssertNil(Story.make(id: "n", title: "x", published: t0, label: "REPORTED").notableReliability)
        XCTAssertEqual(Story.make(id: "d", title: "x", published: t0, label: "DEAL").notableReliability, .deal)
        XCTAssertNil(Story.make(id: "u", title: "x", published: t0, label: "SOMETHING-NEW").reliability)
        XCTAssertTrue(ReliabilityLabel.allCases.allSatisfy { !$0.systemImage.isEmpty && !$0.spokenText.isEmpty })
    }

    func testBriefsSavedByOlderBuildsStillDecode() throws {
        // A brief as the first release stored it: no score, opinion, per-source times or counts.
        let json = """
        {"date":"2026-09-30","generatedAt":"2026-09-30T08:00:00Z","headline":"2 stories from 40 sources",
         "top":[{"id":"a","title":"A","summary":"","importance":1,"label":"REPORTED","category":"Tech",
                 "published":"2026-09-30T07:00:00Z","outletCount":1,
                 "sources":[{"outlet":"The Verge","title":"A","url":"https://example.com/a","official":false}]}],
         "sections":[{"name":"Tech","stories":[{"id":"b","title":"B","summary":"s","importance":1,"label":"CONFIRMED",
                 "category":"Tech","published":"2026-09-30T06:00:00Z","outletCount":1,"sources":[]}]}],
         "sourceProblems":[]}
        """
        let brief = try JSONDecoder.api.decode(Brief.self, from: Data(json.utf8))
        XCTAssertEqual(brief.storyCount, 2)
        XCTAssertNil(brief.sourceCount)
        XCTAssertNil(brief.top[0].score)
        XCTAssertNil(brief.top[0].sources[0].published)
        XCTAssertEqual(brief.stories(inTopic: "Tech").map(\.id), ["a", "b"])
        XCTAssertEqual(brief.allStoriesByScore.map(\.id), ["a", "b"], "old briefs keep their own order")
        // And a new brief round-trips.
        let built = BriefBuilder.build(feed: feed, settings: .default, now: now)
        XCTAssertEqual(try JSONDecoder.api.decode(Brief.self, from: JSONEncoder.api.encode(built)), built)
    }
}
