import XCTest
@testable import PersonalFeed

/// For you: the shuffle, scrolled-past and read stories moving down, and the model's passed marks.
@MainActor
final class FeedOrderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var store: IsolatedStore?
    private var models: [AppModel] = []

    override func tearDown() async throws {
        for model in models {
            await model.flushFeedWrite()
            await model.flushLocalState()
            await model.flushHistory()
        }
        models = []
        store?.tearDown()
        store = nil
    }

    /// A model on a throwaway store that has loaded the fixture feed.
    private func makeModel(_ clock: TestClock, feed: SharedFeed) -> AppModel {
        if store == nil { store = IsolatedStore() }
        let model = AppModel.forTesting(clock: clock)
        model.fetchFeed = { _ in .fresh(feed, data: feed.encoded, etag: nil) }
        models.append(model)
        return model
    }

    private func story(_ id: String, score: Double = 3) -> Story {
        var s = Story.make(id: id, title: id, published: now)
        s.score = score
        return s
    }

    private func stories(_ count: Int, score: Double = 3) -> [Story] {
        (0..<count).map { story("s\($0)", score: score) }
    }

    func testUnseenComeFirstThenPassedThenReadWithTheLatestReadLast() {
        let all = stories(8)
        var order = FeedOrder(seed: 1)
        order.passedAt = ["s1": now.addingTimeInterval(-60), "s5": now.addingTimeInterval(-600)]
        order.readAt = ["s2": now, "s0": now.addingTimeInterval(-30), "s5": now.addingTimeInterval(-5)]

        let ids = order.apply(all).map(\.id)
        XCTAssertEqual(Set(ids.prefix(4)), ["s3", "s4", "s6", "s7"], "not seen yet: on top")
        XCTAssertEqual(Array(ids[4...]), ["s1", "s0", "s5", "s2"],
                       "then scrolled past, then read in the order read; read beats passed (s5)")
        XCTAssertEqual(order.tier(of: "s5"), .read)
        XCTAssertEqual(order.tier(of: "s1"), .passed)
        XCTAssertEqual(order.tier(of: "s3"), .fresh)
    }

    func testSkippedBeforeThisShuffleAreReshuffledAndNewSkipsQueueUpLast() {
        let all = stories(20)
        var order = FeedOrder(seed: 3)
        order.shuffledAt = now
        // s0…s9 skipped on an earlier visit, in that order; s11 then s10 skipped since this shuffle.
        for i in 0..<10 { order.passedAt["s\(i)"] = now.addingTimeInterval(-3600 + Double(i)) }
        order.passedAt["s11"] = now.addingTimeInterval(60)
        order.passedAt["s10"] = now.addingTimeInterval(120)

        let ids = order.apply(all).map(\.id)
        XCTAssertEqual(Set(ids.prefix(8)), Set((12..<20).map { "s\($0)" }), "not seen yet: first")
        let earlier = Array(ids[8..<18])
        XCTAssertEqual(Set(earlier), Set((0..<10).map { "s\($0)" }), "skipped before: next")
        XCTAssertNotEqual(earlier, (0..<10).map { "s\($0)" }, "and not in the order they were skipped")
        XCTAssertEqual(Array(ids[18...]), ["s11", "s10"], "skipped since: oldest first, at the end")
    }

    func testTheShuffleHoldsForASeedAndChangesWithIt() {
        let all = stories(40)
        let a = FeedOrder(seed: 42).apply(all).map(\.id)
        XCTAssertEqual(FeedOrder(seed: 42).apply(all).map(\.id), a, "same seed, same order")
        XCTAssertEqual(FeedOrder(seed: 42).apply(Array(all.reversed())).map(\.id), a, "doesn't depend on the incoming order")
        XCTAssertNotEqual(FeedOrder(seed: 43).apply(all).map(\.id), a, "a new seed reshuffles")
        XCTAssertNotEqual(a, all.map(\.id), "not hot order")
        XCTAssertEqual(Set(a), Set(all.map(\.id)), "nothing lost or repeated")
        XCTAssertEqual(a.count, all.count)

        // Removing a story (read, or gone from the feed) leaves the rest where they were.
        var withRead = FeedOrder(seed: 42)
        withRead.readAt = [a[3]: now]
        XCTAssertEqual(Array(withRead.apply(all).map(\.id).prefix(39)), a.filter { $0 != a[3] })
    }

    func testBigStoriesUsuallyLandNearTheTopButNotAlways() {
        let all = stories(60, score: 2) + [story("big", score: 20)]
        var top3 = 0
        var first = 0
        for seed in UInt64(0)..<200 {
            let ids = FeedOrder(seed: seed).apply(all).map(\.id)
            if ids.prefix(3).contains("big") { top3 += 1 }
            if ids.first == "big" { first += 1 }
        }
        XCTAssertGreaterThan(top3, 180, "six times the coverage nearly always shows early")
        XCTAssertLessThan(first, 200, "but it isn't pinned")

        // Among equals the first spot moves around.
        let firsts = Set((UInt64(0)..<50).compactMap { FeedOrder(seed: $0).apply(stories(30)).first?.id })
        XCTAssertGreaterThan(firsts.count, 10)
    }

    func testNewStoriesGetANudge() {
        let all = stories(30)
        let visit = now.addingTimeInterval(-3600)
        var order = FeedOrder(seed: 0)
        order.newSince = visit
        order.firstSeen = Dictionary(uniqueKeysWithValues: all.map { ($0.id, visit.addingTimeInterval(-60)) })
        order.firstSeen["s7"] = now
        XCTAssertTrue(order.isNew(all[7]))
        XCTAssertFalse(order.isNew(all[6]))
        XCTAssertGreaterThan(order.shuffleKey(all[7]), FeedOrder(seed: 0).shuffleKey(all[7]))
    }

    func testOldBriefsWithoutScoresStillShuffle() {
        let old = (0..<10).map { Story.make(id: "o\($0)", title: "o", published: now) }
        XCTAssertNil(old[0].score)
        XCTAssertEqual(Set(FeedOrder(seed: 9).apply(old).map(\.id)), Set(old.map(\.id)))
    }

    func testUnitRandomIsStableAndInsideZeroOne() {
        XCTAssertEqual(FeedOrder.unitRandom("abc", seed: 7), FeedOrder.unitRandom("abc", seed: 7))
        XCTAssertNotEqual(FeedOrder.unitRandom("abc", seed: 7), FeedOrder.unitRandom("abd", seed: 7))
        XCTAssertNotEqual(FeedOrder.unitRandom("abc", seed: 7), FeedOrder.unitRandom("abc", seed: 8))
        let samples = (0..<2000).map { FeedOrder.unitRandom("story-\($0)", seed: 99) }
        XCTAssertTrue(samples.allSatisfy { $0 > 0 && $0 < 1 })
        let mean = samples.reduce(0, +) / Double(samples.count)
        XCTAssertEqual(mean, 0.5, accuracy: 0.03)
        XCTAssertTrue(FeedOrder(seed: 0).shuffleKey(story("x")).isFinite)
    }

    func testForYouIsTheDefaultSortAndFallsBackToHotOrder() {
        let all = stories(10)
        XCTAssertEqual(StorySort.allCases.first, .forYou, "first, so the default")
        XCTAssertEqual(StorySort.forYou.title, "For you")
        XCTAssertEqual(StorySort.forYou.apply(all).map(\.id), all.map(\.id), "no reader state: hot order")
        let order = FeedOrder(seed: 5)
        XCTAssertEqual(StorySort.forYou.apply(all, order: order).map(\.id), order.apply(all).map(\.id))
        XCTAssertEqual(StorySort.hot.apply(all, order: order).map(\.id), all.map(\.id), "hot ignores it")
    }

    // MARK: On the model

    func testPassedStoriesMoveDownOnlyWhenSunkAndArePersisted() async throws {
        let feed = try Fixture.feed()
        let clock = TestClock(feed.generatedAt.addingTimeInterval(120))
        let model = makeModel(clock, feed: feed)
        await model.refresh(reason: .launch)
        let brief = try XCTUnwrap(model.brief)
        let before = StorySort.forYou.apply(brief.stories, order: model.feedOrder)
        let skipped = before[0], read = before[1]

        model.notePassed(skipped)
        XCTAssertNotNil(model.passedAt[skipped.id])
        XCTAssertEqual(StorySort.forYou.apply(brief.stories, order: model.feedOrder).first?.id, skipped.id,
                       "a pass alone moves nothing, so the list holds still while scrolling")
        XCTAssertTrue(model.sinkPassed())
        XCTAssertFalse(model.sinkPassed(), "nothing new to apply")
        model.markRead(read)
        model.notePassed(read)
        XCTAssertNil(model.passedAt[read.id], "a read story isn't marked passed")

        let after = StorySort.forYou.apply(brief.stories, order: model.feedOrder).map(\.id)
        XCTAssertEqual(after.last, read.id, "read: at the bottom")
        XCTAssertEqual(after[after.count - 2], skipped.id, "scrolled past: just above the read ones")
        XCTAssertEqual(Array(after.prefix(after.count - 2)), before.map(\.id).filter { $0 != skipped.id && $0 != read.id },
                       "the rest keep their places")

        await model.flushLocalState()
        XCTAssertTrue(LocalStore.exists(.passed))
        let next = makeModel(clock, feed: feed)
        await next.restoreCore()
        XCTAssertNotNil(next.passedAt[skipped.id])
        XCTAssertNotNil(next.sunkPassedAt[skipped.id], "applied at launch")

        model.clearUserData()
        XCTAssertTrue(model.passedAt.isEmpty)
        XCTAssertTrue(model.sunkPassedAt.isEmpty)
    }

    func testPullToRefreshAndComingBackLaterReshuffle() async throws {
        let feed = try Fixture.feed()
        let clock = TestClock(feed.generatedAt.addingTimeInterval(120))
        let model = makeModel(clock, feed: feed)
        LocalStore.onboarded = true
        LocalStore.userID = "u1"
        model.fetchAccount = { [model] _ in AccountSnapshot(userID: "u1", settings: model.settings) }
        await model.restore()
        let story = try XCTUnwrap(model.brief?.allStories.first)

        let seed = model.feedSeed
        model.notePassed(story)
        model.reshuffleFeed()
        XCTAssertNotEqual(model.feedSeed, seed)
        XCTAssertNotNil(model.sunkPassedAt[story.id], "a reshuffle also moves what was passed")

        model.sceneDidBecomeActive()
        clock.advance(minutes: 1)
        let current = model.feedSeed
        model.sceneDidEnterBackground()
        clock.advance(minutes: 1)
        model.sceneDidBecomeActive()
        XCTAssertEqual(model.feedSeed, current, "a quick trip to another app keeps the order")

        model.sceneDidEnterBackground()
        clock.advance(minutes: 10)
        model.sceneDidBecomeActive()
        XCTAssertNotEqual(model.feedSeed, current, "back after a while: a new shuffle")
        // Coming back also checks for news; let that finish before the store goes away.
        await waitUntil(model.lastCheckedAt == clock.now && !model.isRefreshing)
        model.sceneWillResignActive()
    }

    // MARK: Scroll tracking

    func testACardCountsAsPassedOnceItsBottomIsAboveTheList() {
        let tracker = FeedScrollTracker()
        tracker.visibleTop = 100
        XCTAssertFalse(tracker.cardMoved("a", frame: CGRect(x: 0, y: 120, width: 300, height: 400)))
        XCTAssertFalse(tracker.cardMoved("a", frame: CGRect(x: 0, y: -200, width: 300, height: 400)), "half off: not yet")
        XCTAssertTrue(tracker.cardMoved("a", frame: CGRect(x: 0, y: -280, width: 300, height: 400)), "only its pills show")
        XCTAssertFalse(tracker.cardMoved("a", frame: CGRect(x: 0, y: -300, width: 300, height: 400)), "reported once")
        XCTAssertFalse(tracker.cardGone("a"), "already reported")

        // Back on screen (scrolled up), then past again: a new pass.
        XCTAssertFalse(tracker.cardMoved("a", frame: CGRect(x: 0, y: 0, width: 300, height: 400)))
        XCTAssertTrue(tracker.cardMoved("a", frame: CGRect(x: 0, y: -350, width: 300, height: 400)))

        // A fast flick: last seen with its top above the list, then gone.
        _ = tracker.cardMoved("b", frame: CGRect(x: 0, y: 60, width: 300, height: 400))
        XCTAssertTrue(tracker.cardGone("b"))
        // Gone off the bottom: not passed.
        _ = tracker.cardMoved("c", frame: CGRect(x: 0, y: 700, width: 300, height: 400))
        XCTAssertFalse(tracker.cardGone("c"))

        _ = tracker.cardMoved("d", frame: CGRect(x: 0, y: 500, width: 300, height: 400))
        _ = tracker.cardMoved("e", frame: CGRect(x: 0, y: 150, width: 300, height: 340))
        XCTAssertEqual(tracker.cardsOnScreen(), ["e", "d"], "top to bottom, without the ones passed or gone")

        XCTAssertFalse(tracker.isQuiet)
        tracker.reset()
        XCTAssertTrue(tracker.isQuiet, "a reset ignores passes for a moment")
    }
}
