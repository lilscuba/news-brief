import XCTest
@testable import PersonalFeed

/// Checking for news: one request at a time, conditional requests that survive a relaunch, no
/// work on "nothing new", no stepping back to an older feed, and no reshuffling under the reader.
@MainActor
final class RefreshTests: XCTestCase {
    private var store: IsolatedStore!
    private var clock: TestClock!
    private var feed: SharedFeed!
    private var data: Data!
    private var model: AppModel!
    private var etag: String { "\"\(feed.generatedAt.formatted(.iso8601))\"" }

    override func setUp() async throws {
        store = IsolatedStore()
        feed = try Fixture.feed()
        data = try Fixture.data()
        clock = TestClock(feed.generatedAt.addingTimeInterval(120))
        model = AppModel.forTesting(clock: clock)
    }

    override func tearDown() async throws {
        await model.flushFeedWrite()
        await model.flushLocalState()
        await model.flushHistory()
        store.tearDown()
    }

    private func newStory(_ id: String, minutesAfterFeed: Double = 5) -> FeedStory {
        FeedStory.make(id: id, title: "Nintendo announces a new Switch model \(id)", category: "Gaming", score: 30,
                       published: feed.generatedAt.addingTimeInterval(minutesAfterFeed * 60))
    }

    func testOverlappingRefreshesShareOneRequest() async {
        var requests = 0
        var release: CheckedContinuation<Void, Never>?
        model.fetchFeed = { [feed, data] _ in
            requests += 1
            await withCheckedContinuation { release = $0 }
            return .fresh(feed!, data: data!, etag: nil)
        }
        async let launch = model.refresh(reason: .launch)
        async let foreground = model.refresh(reason: .foreground)
        async let push = model.refresh(reason: .push)
        await waitUntil(release != nil, "the first request is in flight")
        XCTAssertTrue(model.isRefreshing)
        release?.resume()
        let outcomes = await [launch, foreground, push]
        XCTAssertEqual(requests, 1, "three triggers, one download")
        XCTAssertEqual(Set(outcomes), [.updated(newCount: model.brief?.storyCount ?? -1)])
        XCTAssertFalse(model.isRefreshing)
        XCTAssertNotNil(model.brief)
        XCTAssertEqual(model.lastCheckedAt, clock.now)
        XCTAssertEqual(LocalStore.feedCheckedAt, clock.now)
    }

    func testAutomaticChecksWaitAMinuteButPullToRefreshNeverWaits() async {
        var requests = 0
        model.fetchFeed = { _ in requests += 1; return .notModified }
        await model.refresh(reason: .user)
        clock.advance(minutes: 0.5)
        for reason in [RefreshReason.auto, .foreground, .background] {
            let outcome = await model.refresh(reason: reason)
            XCTAssertEqual(outcome, .unchanged)
        }
        XCTAssertEqual(requests, 1, "automatic checks within a minute are skipped")
        await model.refresh(reason: .user)
        await model.refresh(reason: .push)
        XCTAssertEqual(requests, 3)
        clock.advance(minutes: 2)
        await model.refresh(reason: .auto)
        XCTAssertEqual(requests, 4)
    }

    func testTheETagIsKeptAcrossLaunchesAndSentStrong() async throws {
        var sent: [String?] = []
        model.fetchFeed = { [feed, data, etag] tag in
            sent.append(tag)
            // Cloudflare weakens the Worker's ETag when it compresses the response.
            return .fresh(feed!, data: data!, etag: "W/\(etag)")
        }
        await model.refresh(reason: .launch)
        XCTAssertEqual(sent, [nil], "no cached feed, so an unconditional request")
        await model.flushFeedWrite()
        XCTAssertEqual(LocalStore.feedETag, "W/\(etag)")
        XCTAssertEqual(LocalStore.loadFeed()?.generatedAt, feed.generatedAt)

        // A cold launch: the cached feed and its ETag come back, and the next check is conditional.
        let relaunched = AppModel.forTesting(clock: clock)
        await relaunched.restoreCore()
        XCTAssertEqual(relaunched.feed?.generatedAt, feed.generatedAt)
        var resent: [String?] = []
        relaunched.fetchFeed = { tag in resent.append(tag); return .notModified }
        let outcome = await relaunched.refresh(reason: .launch)
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(resent, [etag], "sent without the W/ prefix, which older Workers never matched")
        XCTAssertNil(relaunched.feedStatus)

        XCTAssertEqual(APIClient.ifNoneMatch("W/\"abc\""), "\"abc\"")
        XCTAssertEqual(APIClient.ifNoneMatch("\"abc\""), "\"abc\"")
        XCTAssertNil(APIClient.ifNoneMatch("  "))
        XCTAssertNil(APIClient.ifNoneMatch(nil))
    }

    func testACachedFeedFromAnOlderBuildGetsAnETagFromItsTimestamp() async throws {
        // Older builds saved feed.json but kept the ETag only in memory.
        XCTAssertTrue(LocalStore.saveFeed(data))
        XCTAssertNil(LocalStore.feedETag)
        await model.restoreCore()
        // The Worker's format, `"<generatedAt>"` as it appears in the feed.
        let fromTimestamp = "\"2026-10-01T21:43:35Z\""
        XCTAssertEqual(model.feedETag, fromTimestamp)
        var sent: [String?] = []
        model.fetchFeed = { tag in sent.append(tag); return .notModified }
        await model.refresh(reason: .launch)
        XCTAssertEqual(sent, [fromTimestamp])
    }

    func testNothingNewSkipsTheRebuildAndTheHistoryWrite() async throws {
        var answer: APIClient.FeedResult = .fresh(feed, data: data, etag: etag)
        model.fetchFeed = { _ in answer }
        await model.refresh(reason: .launch)
        await model.flushHistory()
        var writes = await model.historyStore.writeCount
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.historyIndex.map(\.date), [model.brief?.date])
        let shown = model.brief

        answer = .notModified
        clock.advance(minutes: 3)
        let outcome = await model.refresh(reason: .user)
        XCTAssertEqual(outcome, .unchanged)
        await model.flushHistory()
        writes = await model.historyStore.writeCount
        XCTAssertEqual(writes, 1, "a 304 writes nothing")
        XCTAssertEqual(model.brief, shown)

        // Ten minutes on, the brief is rebuilt so the window slides, but identical content still
        // isn't written again.
        clock.advance(minutes: 10)
        await model.refresh(reason: .user)
        await model.flushHistory()
        writes = await model.historyStore.writeCount
        XCTAssertEqual(writes, 1)

        // Same for the same feed downloaded again (a 200 with an unchanged generatedAt).
        answer = .fresh(feed, data: data, etag: etag)
        await model.refresh(reason: .user)
        await model.flushHistory()
        writes = await model.historyStore.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testAnOlderFeedNeverReplacesANewerOne() async {
        let newer = feed.later(by: 10, adding: [newStory("n1")])
        var answer: APIClient.FeedResult = .fresh(newer, data: newer.encoded, etag: nil)
        model.fetchFeed = { _ in answer }
        await model.refresh(reason: .launch)
        answer = .fresh(feed, data: data, etag: nil)
        let outcome = await model.refresh(reason: .user)
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(model.feed?.generatedAt, newer.generatedAt)
        XCTAssertTrue(model.brief?.allStories.contains { $0.id == "n1" } ?? false)
    }

    func testANewerBriefWaitsWhileTheReaderIsScrolledDown() async throws {
        var answer: APIClient.FeedResult = .fresh(feed, data: data, etag: nil)
        model.fetchFeed = { _ in answer }
        await model.refresh(reason: .launch)
        let shown = try XCTUnwrap(model.brief)
        model.todayIsAtTop = false

        let newer = feed.later(by: 10, adding: [newStory("n1"), newStory("n2")])
        answer = .fresh(newer, data: newer.encoded, etag: nil)
        clock.advance(minutes: 10)
        let outcome = await model.refresh(reason: .auto)
        XCTAssertEqual(outcome, .updated(newCount: 2))
        XCTAssertEqual(model.brief, shown, "rows don't move under the reader")
        XCTAssertEqual(model.pendingNewCount, 2)
        XCTAssertNotNil(model.pendingBrief)

        model.todayIsAtTop = true
        XCTAssertNil(model.pendingBrief, "scrolling back to the top shows it")
        XCTAssertEqual(model.pendingNewCount, 0)
        XCTAssertTrue(model.brief?.allStories.contains { $0.id == "n2" } ?? false)

        // Pull to refresh applies at once, even scrolled down.
        model.todayIsAtTop = false
        let newest = feed.later(by: 20, adding: [newStory("n3"), newStory("n1"), newStory("n2")])
        answer = .fresh(newest, data: newest.encoded, etag: nil)
        await model.refresh(reason: .user)
        XCTAssertNil(model.pendingBrief)
        XCTAssertTrue(model.brief?.allStories.contains { $0.id == "n3" } ?? false)

        // A held brief is never kept across a date change.
        let tomorrow = feed.later(by: 26 * 60, adding: [newStory("n4", minutesAfterFeed: 26 * 60 - 5)])
        answer = .fresh(tomorrow, data: tomorrow.encoded, etag: nil)
        clock.advance(minutes: 26 * 60)
        await model.refresh(reason: .auto)
        XCTAssertNil(model.pendingBrief)
        XCTAssertEqual(model.brief?.date, Brief.day(of: clock.now))
    }

    func testFeedProblemsAreNamedHonestly() async {
        var requests = 0
        var error: Error = URLError(.notConnectedToInternet)
        model.fetchFeed = { _ in requests += 1; throw error }
        var outcome = await model.refresh(reason: .user)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(model.feedStatus, .offline)
        XCTAssertEqual(requests, 1, "no retry when there's no connection")
        XCTAssertNil(model.lastCheckedAt)

        error = APIError.server(503, "feed not built yet")
        requests = 0
        await model.refresh(reason: .user)
        XCTAssertEqual(model.feedStatus, .server(503))
        XCTAssertEqual(requests, 2, "a server error is retried once")

        error = URLError(.timedOut)
        requests = 0
        await model.refresh(reason: .user)
        XCTAssertEqual(model.feedStatus, .offline)
        XCTAssertEqual(requests, 2, "so is a timeout")

        requests = 0
        await model.refresh(reason: .background)
        XCTAssertEqual(requests, 1, "but not in the short background window")

        error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "new schema"))
        await model.refresh(reason: .user)
        XCTAssertEqual(model.feedStatus, .unreadable)

        error = APIError.notConfigured
        await model.refresh(reason: .user)
        XCTAssertEqual(model.feedStatus, .notConfigured)

        // A retry that works clears the problem.
        var calls = 0
        model.fetchFeed = { [feed, data] _ in
            calls += 1
            if calls == 1 { throw APIError.server(500, "internal error") }
            return .fresh(feed!, data: data!, etag: nil)
        }
        outcome = await model.refresh(reason: .user)
        XCTAssertEqual(outcome, .updated(newCount: model.brief?.storyCount ?? -1))
        XCTAssertNil(model.feedStatus)
        XCTAssertNil(model.accountError, "feed problems never show as account errors")
    }

    func testOnlyBriefSettingsRebuild() async {
        model.fetchFeed = { [feed, data] _ in .fresh(feed!, data: data!, etag: nil) }
        await model.refresh(reason: .launch)
        await model.flushHistory()
        var s = model.settings
        s.alerts.maxPerDay = 2
        s.brief.hour = 6
        model.update(s)
        await model.flushHistory()
        var writes = await model.historyStore.writeCount
        XCTAssertEqual(writes, 1)

        s.setCategory("Tech", enabled: false)
        model.update(s)
        XCTAssertFalse(model.brief?.sections.contains { $0.name == "Tech" } ?? true, "applied at once")
        await model.flushHistory()
        writes = await model.historyStore.writeCount
        XCTAssertEqual(writes, 2)
    }
}
