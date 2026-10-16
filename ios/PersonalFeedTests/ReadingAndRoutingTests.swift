import XCTest
@testable import PersonalFeed

/// Read, new, saved and recently read on the model, and where tapped notifications land.
@MainActor
final class ReadingAndRoutingTests: XCTestCase {
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

    private func relaunch() async -> AppModel {
        await model.flushLocalState()
        let next = AppModel.forTesting(clock: clock)
        next.fetchFeed = model.fetchFeed
        await next.restoreCore()
        return next
    }

    /// Signed in, onboarded and past the first check, the way a launch leaves it.
    private func readyModel() async {
        LocalStore.onboarded = true
        LocalStore.userID = "u1"
        model.fetchAccount = { [model] _ in AccountSnapshot(userID: "u1", settings: model!.settings) }
        await model.restore()
        XCTAssertEqual(model.phase, .ready)
    }

    // MARK: Read

    func testReadStateIsDatedUndoableAndPersisted() async throws {
        await model.refresh(reason: .launch)
        let stories = Array(try XCTUnwrap(model.brief).allStories.prefix(5))
        model.markRead(stories[0])
        XCTAssertTrue(model.isRead(stories[0]))
        model.toggleRead(stories[0])
        XCTAssertFalse(model.isRead(stories[0]), "read can be undone")

        model.markRead(stories[1])
        let marked = model.markRead(stories)
        XCTAssertEqual(marked.map(\.id), [stories[0], stories[2], stories[3], stories[4]].map(\.id),
                       "mark all returns only what it changed, for undo")
        model.setRead(marked, false)
        XCTAssertEqual(stories.filter(model.isRead).map(\.id), [stories[1].id], "undo leaves earlier reads alone")
        XCTAssertEqual(model.readAt[stories[1].id], clock.now)

        let next = await relaunch()
        XCTAssertTrue(next.isRead(stories[1]))
        XCTAssertFalse(next.isRead(stories[0]))
    }

    func testReadIDsFromOlderBuildsAreKept() async throws {
        LocalStore.defaults.set(["a", "b"], forKey: "readIDs")
        await model.restoreCore()
        let a = Story.make(id: "a", title: "A", published: clock.now)
        XCTAssertTrue(model.isRead(a))
        XCTAssertEqual(model.readAt["b"], clock.now, "migrated as read now")
        await model.flushLocalState()
        XCTAssertTrue(LocalStore.exists(.read))

        // read.json wins from now on.
        model.setRead(a, false)
        let next = await relaunch()
        XCTAssertFalse(next.isRead(a))
        XCTAssertNotNil(next.readAt["b"])
    }

    func testAnUnreadableFileIsSetAsideNotWiped() async throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{oops".utf8).write(to: LocalStore.url(.saved))
        await model.restoreCore()
        XCTAssertTrue(model.saved.isEmpty)
        let aside = store.directory.appending(path: "saved.unreadable.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path), "kept for recovery")
    }

    // MARK: New since the last visit

    func testNothingIsNewOnTheFirstRunThenNewStoriesAre() async throws {
        await model.refresh(reason: .launch)
        model.previousVisitAt = clock.now.addingTimeInterval(-3600)
        XCTAssertTrue(model.newStories.isEmpty, "no 900 'new' stories on day one")
        XCTAssertNil(model.newSince)

        let fresh = FeedStory.make(id: "fresh", title: "Valve announces Half-Life 3", category: "Gaming", score: 40,
                                   published: clock.now.addingTimeInterval(60))
        clock.advance(minutes: 5)
        model.fetchFeed = { [feed] _ in let f = feed!.later(by: 7, adding: [fresh]); return .fresh(f, data: f.encoded, etag: nil) }
        await model.refresh(reason: .user)
        XCTAssertEqual(model.newStories.map(\.id), ["fresh"])
        XCTAssertEqual(model.newSince, model.previousVisitAt)
        XCTAssertEqual(model.newCount(inTopic: "Gaming"), 1)
        XCTAssertEqual(model.newCount(inTopic: "AI"), 0)
        XCTAssertEqual(model.newStoryCount(since: model.previousVisitAt), 1, "the badge count")

        let story = try XCTUnwrap(model.newStories.first)
        model.markRead(story)
        XCTAssertTrue(model.newStories.isEmpty, "read stories aren't new")

        // A relaunch remembers what was already seen.
        let next = await relaunch()
        XCTAssertNotNil(next.firstSeen["fresh"])
        XCTAssertNotEqual(next.firstSeen["fresh"], ReadingState.seeded)
    }

    func testAVisitOnlyCountsAfterTenSeconds() async {
        await readyModel()
        model.sceneDidBecomeActive()
        clock.advance(minutes: 0.1)
        model.sceneDidEnterBackground()
        XCTAssertNil(LocalStore.lastVisitAt, "a glance doesn't reset what's new")

        model.sceneDidBecomeActive()
        clock.advance(minutes: 1)
        model.sceneDidEnterBackground()
        XCTAssertEqual(LocalStore.lastVisitAt, clock.now)

        let leftAt = clock.now
        clock.advance(minutes: 60)
        model.sceneDidBecomeActive()
        XCTAssertEqual(model.previousVisitAt, leftAt, "the new visit compares against the last one")
        // Coming back after an hour also checks for news.
        await waitUntil(model.lastCheckedAt == clock.now && !model.isRefreshing)
        model.sceneWillResignActive()
    }

    // MARK: Saved and recently read

    func testSavedAndRecentlyReadStayOnThePhone() async throws {
        await model.refresh(reason: .launch)
        let stories = Array(try XCTUnwrap(model.brief).allStories.prefix(3))
        model.toggleSaved(stories[0])
        model.setSaved(stories[1], true)
        model.setSaved(stories[1], true)
        XCTAssertEqual(model.saved.map(\.id), [stories[1].id, stories[0].id], "newest first, no duplicates")
        model.toggleSaved(stories[0])
        XCTAssertFalse(model.isSaved(stories[0]))

        model.openArticle(stories[2])
        XCTAssertEqual(model.presentedArticle?.url, stories[2].sources.first?.url)
        XCTAssertEqual(model.presentedArticle?.storyID, stories[2].id)
        XCTAssertTrue(model.isRead(stories[2]), "opening the article marks the story read")
        model.noteOpened(stories[0])
        model.noteOpened(stories[2])
        XCTAssertEqual(model.recent.map(\.id), [stories[2].id, stories[0].id], "most recent first, once each")

        for i in 0..<60 { model.noteOpened(Story.make(id: "r\(i)", title: "R\(i)", published: clock.now)) }
        XCTAssertEqual(model.recent.count, ReadingState.recentCap)
        XCTAssertEqual(model.recent.first?.id, "r59")

        let next = await relaunch()
        XCTAssertEqual(next.saved.map(\.id), [stories[1].id])
        XCTAssertEqual(next.recent.count, ReadingState.recentCap)

        LocalStore.resetForNewUser("someone-else")
        next.clearUserData()
        XCTAssertTrue(next.saved.isEmpty && next.recent.isEmpty && next.readAt.isEmpty)
        XCTAssertFalse(LocalStore.exists(.saved) || LocalStore.exists(.recent) || LocalStore.exists(.read))
    }

    // MARK: Topics

    func testTopicPagesAreLiveAndUnfollowedTopicsCanBeBrowsed() async throws {
        await model.refresh(reason: .launch)
        let brief = try XCTUnwrap(model.brief)
        XCTAssertEqual(model.stories(inTopic: "Tech").map(\.id), brief.stories(inTopic: "Tech").map(\.id))
        XCTAssertFalse(model.isFollowing("US"))
        // The fixture has no US stories, but browsing an unfollowed topic works through the all-topics brief.
        XCTAssertEqual(model.stories(inTopic: "US"), [])
        model.setFollowing("Gaming", false)
        XCTAssertFalse(model.isFollowing("Gaming"))
        XCTAssertFalse(model.stories(inTopic: "Gaming").isEmpty, "still browsable after unfollowing")
        XCTAssertFalse(model.brief?.sections.contains { $0.name == "Gaming" } ?? true)
        model.setFollowing("Gaming", true)
        XCTAssertEqual(model.settings.categories.last, "Gaming", "following again appends it")

        XCTAssertFalse(model.search("anthropic", scope: .mine).isEmpty)
        XCTAssertGreaterThanOrEqual(model.search("nintendo", scope: .all).count, model.search("nintendo", scope: .mine).count)
        let story = try XCTUnwrap(brief.allStories.first { !model.relatedStories(to: $0).isEmpty } ?? brief.allStories.first)
        XCTAssertFalse(model.relatedStories(to: story).contains { $0.id == story.id })
    }

    // MARK: Notifications

    func testNotificationPayloadsAreParsed() {
        XCTAssertEqual(NotificationRoute(userInfo: ["kind": "brief"]), .today)
        XCTAssertEqual(NotificationRoute(userInfo: [:]), .today)
        XCTAssertEqual(NotificationRoute(userInfo: ["kind": "alert", "storyId": "abc", "url": "https://example.com/a"]),
                       .story(id: "abc", url: URL(string: "https://example.com/a")))
        XCTAssertEqual(NotificationRoute(userInfo: ["url": "https://example.com/a"]),
                       .story(id: nil, url: URL(string: "https://example.com/a")))
    }

    func testATappedAlertOpensItsStoryOnTodayOnceTheAppIsReady() async throws {
        let target = try XCTUnwrap(BriefBuilder.build(feed: feed, settings: .default, now: clock.now).allStories.dropFirst(3).first)
        // A cold launch from a push: the tap arrives before anything is restored.
        model.handleNotification(.story(id: target.id, url: nil))
        XCTAssertNotNil(model.pendingRoute, "held until the app is ready")
        model.selectedTab = .settings
        await readyModel()
        await waitUntil(model.pendingRoute == nil && !model.todayPath.isEmpty)
        XCTAssertEqual(model.selectedTab, .today)
        XCTAssertEqual(model.todayPath.count, 1)
        XCTAssertTrue(model.isRead(target))
        XCTAssertEqual(model.recent.first?.id, target.id)
        XCTAssertNil(model.presentedArticle)

        // "Brief ready" pops back to the top of Today: the list, not old search results.
        model.selectedTab = .saved
        model.searchQuery = "nintendo"
        model.isSearchPresented = true
        let scrolls = model.scrollToTopRequest
        model.handleNotification(.today)
        await waitUntil(model.todayPath.isEmpty && model.selectedTab == .today)
        XCTAssertEqual(model.scrollToTopRequest, scrolls + 1)
        XCTAssertEqual(model.searchQuery, "")
        XCTAssertFalse(model.isSearchPresented)
    }

    func testAlertsResolveOutsideTheBriefAndFallBackToTheArticle() async throws {
        await readyModel()
        model.setFollowing("Gaming", false)
        let gaming = try XCTUnwrap(feed.stories.first { $0.category == "Gaming" && $0.label != "DEAL" })
        XCTAssertEqual(model.resolveStory(id: gaming.id, url: nil)?.id, gaming.id, "found in the feed")
        let byURL = model.resolveStory(id: "not-the-feed-id", url: gaming.sources[0].url)
        XCTAssertEqual(byURL?.id, gaming.id, "alert ids can differ from the feed's, so the URL is tried")

        let elsewhere = URL(string: "https://example.com/not-in-the-feed")!
        model.handleNotification(.story(id: "unknown", url: elsewhere))
        await waitUntil(model.presentedArticle != nil)
        XCTAssertEqual(model.presentedArticle?.url, elsewhere, "the article opens when the story isn't known")
        XCTAssertTrue(model.todayPath.isEmpty)
    }

    func testANewVisitTakesTheHideReadSnapshotAndAccountResetForgetsSearches() async throws {
        await readyModel()
        let story = try XCTUnwrap(model.brief?.allStories.first)
        model.setRead(story, true)
        XCTAssertFalse(model.todayReadSnapshot?.contains(story.id) ?? false, "read during this visit: still shown")
        model.sceneDidEnterBackground()
        model.sceneDidBecomeActive()
        XCTAssertTrue(model.todayReadSnapshot?.contains(story.id) ?? false, "the next visit hides it")

        LocalStore.defaults.set("nintendo", forKey: RecentSearches.storageKey)  // .standard in the app
        LocalStore.resetForNewUser("someone-else")
        XCTAssertNil(LocalStore.defaults.string(forKey: RecentSearches.storageKey))
    }

    func testOnlyWebPagesOpenInTheBrowser() async throws {
        await readyModel()
        model.openArticle(url: try XCTUnwrap(URL(string: "javascript:alert(1)")))
        XCTAssertNil(model.presentedArticle, "SFSafariViewController throws on non-web URLs")
        model.openArticle(url: try XCTUnwrap(URL(string: "HTTPS://example.com/a")))
        XCTAssertNotNil(model.presentedArticle)
    }

    func testSigningOutClearsNavigationAndErrors() async throws {
        await readyModel()
        model.todayPath.append(TopicDestination(name: "Tech"))
        model.openArticle(url: URL(string: "https://example.com")!)
        model.accountError = "Couldn't delete your account"
        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertTrue(model.todayPath.isEmpty)
        XCTAssertNil(model.presentedArticle)
        XCTAssertNil(model.accountError, "a deliberate sign-out shows no error")
        XCTAssertNil(model.feedStatus)
    }
}
