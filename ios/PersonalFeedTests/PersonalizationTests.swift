import XCTest
@testable import PersonalFeed

/// Learning what the reader reads, one-motion swipes, the swipe-to-save tip and the 10 minutes a
/// read story stays in lists that hide read stories.
@MainActor
final class PersonalizationTests: XCTestCase {
    private var store: IsolatedStore!
    private var clock: TestClock!
    private var feed: SharedFeed!
    private var model: AppModel!

    override func setUp() async throws {
        store = IsolatedStore()
        feed = try Fixture.feed()
        clock = TestClock(feed.generatedAt.addingTimeInterval(120))
        model = AppModel.forTesting(clock: clock)
        model.fetchFeed = { [feed] _ in .fresh(feed!, data: feed!.encoded, etag: nil) }
    }

    override func tearDown() async throws {
        await model.flushFeedWrite()
        await model.flushLocalState()
        await model.flushHistory()
        store.tearDown()
    }

    /// Signed in, onboarded and past the first check, the way a launch leaves it.
    private func readyModel() async {
        LocalStore.onboarded = true
        LocalStore.userID = "u1"
        model.fetchAccount = { [model] _ in AccountSnapshot(userID: "u1", settings: model!.settings) }
        await model.restore()
        XCTAssertEqual(model.phase, .ready)
    }

    private func story(_ id: String, _ title: String, category: String = "Gaming", outlet: String = "VGC") -> Story {
        let source = Source(outlet: outlet, title: title, url: URL(string: "https://example.com/\(id)")!, official: false)
        return Story.make(id: id, title: title, category: category, published: clock.now, sources: [source])
    }

    // MARK: Interest profile

    func testEachSignalCountsOncePerStoryAndWeighsMoreForSaving() {
        var profile = InterestProfile()
        let zelda = story("z1", "Nintendo dates the next Zelda for March")
        XCTAssertTrue(profile.record(zelda, .opened, now: clock.now))
        XCTAssertFalse(profile.record(zelda, .opened, now: clock.now), "reopening doesn't count again")
        XCTAssertTrue(profile.record(zelda, .readArticle, now: clock.now))
        XCTAssertTrue(profile.record(zelda, .saved, now: clock.now))
        XCTAssertEqual(profile.total, 1 + 1.5 + 2, accuracy: 0.001)
        XCTAssertEqual(profile.topics["Gaming"] ?? 0, 4.5, accuracy: 0.001)
        XCTAssertEqual(profile.outlets["VGC"] ?? 0, 4.5, accuracy: 0.001)
        XCTAssertNotNil(profile.terms["zelda"])
        XCTAssertNil(profile.terms["the"], "stop words aren't interests")

        // The outlet whose article was read gets the credit, not the lead.
        profile.record(story("z2", "Switch 2 sales pass 20 million"), .readArticle, outlet: "Eurogamer", now: clock.now)
        XCTAssertEqual(profile.outlets["Eurogamer"] ?? 0, 1.5, accuracy: 0.001)
    }

    func testOldReadingFadesWithAThreeWeekHalfLife() {
        var profile = InterestProfile()
        profile.record(story("a", "PlayStation Plus games for October"), .saved, now: clock.now)
        profile.fade(to: clock.now.addingTimeInterval(21 * 86_400))
        XCTAssertEqual(profile.total, 1, accuracy: 0.001)
        XCTAssertEqual(profile.topics["Gaming"] ?? 0, 1, accuracy: 0.001)
        profile.fade(to: clock.now)  // a clock set back never adds weight
        XCTAssertEqual(profile.total, 1, accuracy: 0.001)
    }

    func testTheProfileStaysSmall() {
        var profile = InterestProfile()
        for i in 0..<300 {
            profile.record(story("s\(i)", "Unique\(i)alpha Unique\(i)beta headline"), .opened,
                           outlet: "Outlet \(i)", now: clock.now)
        }
        XCTAssertLessThanOrEqual(profile.terms.count, InterestProfile.maxTerms)
        XCTAssertLessThanOrEqual(profile.outlets.count, InterestProfile.maxOutlets)
        // Counted signals are forgotten after a few days.
        profile.record(story("late", "One more headline"), .opened, now: clock.now.addingTimeInterval(5 * 86_400))
        XCTAssertEqual(profile.counted.count, 1)
    }

    func testTopListsTheHeaviestFirst() {
        XCTAssertEqual(InterestProfile.top(["AI": 1, "Gaming": 5, "Tech": 3, "Deals": 0.2], 2), ["Gaming", "Tech"])
    }

    // MARK: Scoring

    func testNothingIsBoostedUntilThereIsEnoughReading() {
        var profile = InterestProfile()
        profile.record(story("a", "Zelda remake announced"), .readArticle, now: clock.now)
        XCTAssertNil(InterestScorer(profile: profile, titles: ["Zelda remake announced"]),
                     "one article doesn't reorder the feed")
    }

    func testStoriesLikeTheOnesReadScoreHigherAndRareWordsCountMore() throws {
        var profile = InterestProfile()
        for i in 0..<10 {
            profile.record(story("g\(i)", "Zelda game news \(i)"), .readArticle, now: clock.now)
        }
        let titles = (0..<40).map { "Another game update \($0)" } + ["Zelda shadow drop", "Fresh game patch notes"]
        let scorer = try XCTUnwrap(InterestScorer(profile: profile, titles: titles))
        let zelda = scorer.boost(title: "Zelda shadow drop", category: "Gaming", outlets: ["VGC"])
        let common = scorer.boost(title: "Fresh game patch notes", category: "Gaming", outlets: ["VGC"])
        let elsewhere = scorer.boost(title: "Fresh game patch notes", category: "Tech", outlets: ["The Verge"])
        XCTAssertGreaterThan(zelda, common, "a rare word the reader likes says more than a common one")
        XCTAssertGreaterThan(common, elsewhere, "the reader's topic and outlet count")
        XCTAssertEqual(elsewhere, scorer.boost(title: "Unrelated", category: "Tech", outlets: []), accuracy: 0.11)
        let most = InterestScorer.topicWeight + InterestScorer.outletWeight + InterestScorer.termWeight
        XCTAssertLessThanOrEqual(zelda, most)
    }

    func testTheBriefPutsWhatTheReaderReadsHigher() throws {
        let now = feed.generatedAt
        let plain = BriefBuilder.build(feed: feed, settings: .default, now: now)
        let gaming = plain.stories.filter { $0.category == "Gaming" }
        var profile = InterestProfile()
        for s in gaming.prefix(12) { profile.record(s, .readArticle, now: now) }
        let personal = BriefBuilder.build(feed: feed, settings: .default, now: now, interests: profile)

        func meanRank(_ brief: Brief) -> Double {
            let ranks = brief.stories.enumerated().filter { $0.element.category == "Gaming" }.map { Double($0.offset) }
            return ranks.reduce(0, +) / Double(max(ranks.count, 1))
        }
        XCTAssertLessThan(meanRank(personal), meanRank(plain), "Gaming moves up for a Gaming reader")
        XCTAssertEqual(Set(personal.allStories.map(\.id)), Set(plain.allStories.map(\.id)), "nothing added or dropped")
        XCTAssertEqual(BriefBuilder.build(feed: feed, settings: .default, now: now, interests: InterestProfile()),
                       plain, "an empty profile changes nothing")
    }

    // MARK: Learning in the app

    func testOpeningReadingAndSavingTeachTheModelAndPersist() async throws {
        await readyModel()
        let stories = Array(try XCTUnwrap(model.brief).allStories.prefix(3))
        model.noteOpened(stories[0])
        model.openArticle(stories[1])
        model.setSaved(stories[2], true)
        model.setRead(stories[0], false)
        model.setRead(stories[0], true)  // a swipe says nothing either way
        XCTAssertEqual(model.interests.total, 1 + 1.5 + 2, accuracy: 0.001)

        await model.flushLocalState()
        let next = AppModel.forTesting(clock: clock)
        await next.restoreCore()
        XCTAssertEqual(next.interests, model.interests)

        model.resetInterests()
        XCTAssertTrue(model.interests.isEmpty)
    }

    func testANotificationTapIsNotAnInterest() async throws {
        await readyModel()
        let story = try XCTUnwrap(model.brief?.allStories.first)
        model.handleNotification(.story(id: story.id, url: nil))
        await waitUntil(!model.todayPath.isEmpty)
        XCTAssertTrue(model.isRead(story))
        XCTAssertTrue(model.interests.isEmpty)
    }

    func testPullToRefreshReranksAfterReadingButAutomaticChecksDont() async throws {
        await readyModel()
        model.fetchFeed = { _ in .notModified }
        let before = try XCTUnwrap(model.brief)
        let gaming = before.allStories.filter { $0.category == "Gaming" }
        for s in gaming.prefix(12) { model.learn(from: s, .readArticle) }

        clock.advance(minutes: 2)
        await model.refresh(reason: .auto)
        XCTAssertEqual(model.brief, before, "nothing reshuffles while reading")

        await model.refresh(reason: .user)
        XCTAssertNotEqual(model.brief?.stories.map(\.id), before.stories.map(\.id), "pull to refresh re-ranks")

        model.setPersonalizes(false)
        XCTAssertEqual(model.brief?.stories.map(\.id), before.stories.map(\.id), "turned off: the feed's own order")
        XCTAssertFalse(LocalStore.personalizes)
    }

    // MARK: Swipe-to-save tip

    func testTheTipIsDueOnceEveryThirtyMinutesUnlessTurnedOff() {
        let t = clock.now
        XCTAssertTrue(SwipeTip.isDue(now: t, lastShown: nil, disabled: false))
        XCTAssertFalse(SwipeTip.isDue(now: t.addingTimeInterval(29 * 60), lastShown: t, disabled: false))
        XCTAssertTrue(SwipeTip.isDue(now: t.addingTimeInterval(30 * 60), lastShown: t, disabled: false))
        XCTAssertFalse(SwipeTip.isDue(now: t.addingTimeInterval(3600), lastShown: t, disabled: true))
        XCTAssertTrue(SwipeTip.isDue(now: t, lastShown: t.addingTimeInterval(3 * 3600), disabled: false),
                      "a clock set back by hours doesn't silence it")
    }

    func testClosingAnArticleShowsTheTipThenItSleepsAndCanBeTurnedOff() async throws {
        await readyModel()
        let stories = Array(try XCTUnwrap(model.brief).allStories.prefix(4))

        model.openArticle(stories[0])
        model.presentedArticle = nil
        model.articleDidClose()
        XCTAssertEqual(model.swipeTip?.story.id, stories[0].id)
        model.dismissSwipeTip()
        XCTAssertNil(model.swipeTip)

        clock.advance(minutes: 10)
        model.openArticle(stories[1])
        model.presentedArticle = nil
        model.articleDidClose()
        XCTAssertNil(model.swipeTip, "asleep for 30 minutes after showing")

        clock.advance(minutes: 25)
        model.setSaved(stories[2], true)
        model.openArticle(stories[2])
        model.presentedArticle = nil
        model.articleDidClose()
        XCTAssertNil(model.swipeTip, "no tip for a story that's already saved")

        model.openArticle(stories[3])
        model.presentedArticle = nil
        model.articleDidClose()
        XCTAssertEqual(model.swipeTip?.story.id, stories[3].id, "awake again after 30 minutes")
        model.dismissSwipeTip(forever: true)
        XCTAssertTrue(LocalStore.swipeTipDisabled)

        clock.advance(minutes: 120)
        model.openArticle(stories[1])
        model.presentedArticle = nil
        model.articleDidClose()
        XCTAssertNil(model.swipeTip, "Don't Show Again is for good")
    }

    func testALinkWithoutAStoryShowsNoTip() async throws {
        await readyModel()
        model.openArticle(url: URL(string: "https://example.com/elsewhere")!)
        model.presentedArticle = nil
        model.articleDidClose()
        XCTAssertNil(model.swipeTip)
    }

    // MARK: Read stories stay ten minutes

    func testReadStoriesOnlyHideTenMinutesAfterReading() async throws {
        await readyModel()
        let stories = Array(try XCTUnwrap(model.brief).allStories.prefix(2))
        model.setRead(stories[0], true)
        clock.advance(minutes: 9)
        model.setRead(stories[1], true)
        XCTAssertTrue(model.readIDsToHide().isEmpty, "both read under 10 minutes ago")
        XCTAssertFalse(model.isReadAWhileAgo(stories[0]))

        clock.advance(minutes: 1)
        XCTAssertEqual(model.readIDsToHide(), [stories[0].id])
        XCTAssertTrue(model.isReadAWhileAgo(stories[0]))
        XCTAssertEqual(ReadingState.hideable([stories[1].id: clock.now], now: clock.now.addingTimeInterval(600)),
                       [stories[1].id])
    }

    func testANewVisitRightAfterReadingInSafariKeepsTheStory() async throws {
        await readyModel()
        let story = try XCTUnwrap(model.brief?.allStories.first)
        model.noteOpened(story, signal: .readArticle)  // "Open in Safari" leaves the app
        model.sceneDidEnterBackground()
        clock.advance(minutes: 2)
        model.sceneDidBecomeActive()
        XCTAssertFalse(model.todayReadSnapshot?.contains(story.id) ?? false, "still there to be saved")
        model.sceneWillResignActive()
    }

    // MARK: Swipes and taps

    func testSwipesActPastTheThresholdAndSideWithoutAnActionStaysPut() {
        XCTAssertNil(SwipeRule.outcome(SwipeRule.threshold - 1))
        XCTAssertEqual(SwipeRule.outcome(SwipeRule.threshold), .leading, "swipe right: read")
        XCTAssertEqual(SwipeRule.outcome(-SwipeRule.threshold), .trailing, "swipe left: save")
        XCTAssertEqual(SwipeRule.offset(50, canLead: true, canTrail: true), 50)
        XCTAssertEqual(SwipeRule.offset(50, canLead: false, canTrail: true), 0)
        XCTAssertEqual(SwipeRule.offset(-50, canLead: true, canTrail: false), 0)
        let far = SwipeRule.offset(-400, canLead: true, canTrail: true)
        XCTAssertLessThan(far, -SwipeRule.threshold)
        XCTAssertGreaterThan(far, -400, "stiffer past the limit")
        XCTAssertTrue(SwipeRule.isSideways(CGSize(width: 30, height: 5)))
        XCTAssertFalse(SwipeRule.isSideways(CGSize(width: 12, height: 20)), "a scroll isn't a swipe")
    }

    func testTappingARowOpensItsPageOnItsOwnTabOnce() async throws {
        await readyModel()
        let stories = Array(try XCTUnwrap(model.brief).allStories.prefix(2))
        model.push(stories[0], in: .today)
        model.push(stories[0], in: .today)
        XCTAssertEqual(model.todayPath.count, 1, "a double tap opens it once")
        model.push(stories[1], day: "2026-09-30", in: .saved)
        XCTAssertEqual(model.savedPath.count, 1)
        XCTAssertEqual(model.todayPath.count, 1)
    }

    // MARK: Bugs

    func testACancelledCheckIsNotReportedAsOffline() async {
        model.fetchFeed = { _ in throw URLError(.cancelled) }
        let outcome = await model.refresh(reason: .user)
        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(model.feedStatus)
        model.fetchFeed = { _ in throw URLError(.notConnectedToInternet) }
        await model.refresh(reason: .user)
        XCTAssertEqual(model.feedStatus, .offline)
    }
}
