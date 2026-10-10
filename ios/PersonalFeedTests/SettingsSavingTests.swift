import XCTest
@testable import PersonalFeed

/// Topic choices must survive slow, overlapping and failing saves.
@MainActor
final class SettingsSavingTests: XCTestCase {
    private var store: IsolatedStore!
    private var clock: TestClock!
    private var model: AppModel!

    override func setUp() async throws {
        store = IsolatedStore()
        clock = TestClock(Date())
        model = AppModel.forTesting(clock: clock)
    }

    override func tearDown() async throws {
        await model.flushFeedWrite()
        await model.flushLocalState()
        await model.flushHistory()
        store.tearDown()
    }

    private func with(_ categories: [String]) -> UserSettings {
        var s = model.settings
        s.categories = categories
        return s
    }

    func testAChoiceSavesByItself() async {
        var sent: [UserSettings] = []
        model.sendSettings = { settings, _ in sent.append(settings); return settings }
        model.update(with(["AI", "World"]))
        XCTAssertTrue(model.hasPendingSettings)
        await waitUntil(model.saveState == .saved)
        XCTAssertEqual(sent.last?.categories, ["AI", "World"])
        XCTAssertFalse(model.hasPendingSettings)
    }

    func testATapDuringASaveIsNotUndoneByTheOlderReply() async {
        // The first request is held open; meanwhile the user taps another topic.
        var sent: [[String]] = []
        var release: CheckedContinuation<Void, Never>?
        model.sendSettings = { settings, _ in
            sent.append(settings.categories)
            if sent.count == 1 { await withCheckedContinuation { release = $0 } }
            return settings  // the server echoes what it was sent
        }
        model.update(with(["AI", "World"]))
        await waitUntil(release != nil, "first save should be in flight")
        model.update(with(["AI", "World", "Europe"]))
        release?.resume()
        await waitUntil(model.saveState == .saved && !model.hasPendingSettings)
        XCTAssertEqual(model.settings.categories, ["AI", "World", "Europe"], "the second tap must stick")
        XCTAssertEqual(sent.last, ["AI", "World", "Europe"], "and reach the account")
    }

    func testAFailedSaveKeepsTheChoiceAndStaysPending() async {
        model.sendSettings = { _, _ in throw URLError(.notConnectedToInternet) }
        model.update(with(["Gaming", "Korea"]))
        await waitUntil({ if case .failed = self.model.saveState { return true } else { return false } }())
        XCTAssertEqual(model.settings.categories, ["Gaming", "Korea"])
        XCTAssertTrue(model.hasPendingSettings, "kept to retry when back online")

        var sent: [UserSettings] = []
        model.sendSettings = { settings, _ in sent.append(settings); return settings }
        model.flushPendingSettings()
        await waitUntil(model.saveState == .saved)
        XCTAssertEqual(sent.last?.categories, ["Gaming", "Korea"])
        XCTAssertFalse(model.hasPendingSettings)
    }

    func testARunOfTogglesIsOneRequest() async {
        var requests = 0
        model.saveDelay = .milliseconds(150)
        model.sendSettings = { settings, _ in requests += 1; return settings }
        model.update(with(["AI"]))
        model.update(with(["AI", "Tech"]))
        model.update(with(["AI", "Tech", "World"]))
        await waitUntil(model.saveState == .saved)
        XCTAssertEqual(requests, 1)
    }

    func testARejectedSaveStopsRetryingAndShowsTheAccountsCopy() async {
        var account = model.settings
        account.categories = ["AI", "Tech"]
        var attempts = 0
        model.sendSettings = { _, _ in
            attempts += 1
            throw APIError.server(400, "disabledSources: at most 100 entries")
        }
        model.fetchAccount = { _ in AccountSnapshot(userID: "u1", settings: account) }
        model.update(with(["AI", "Tech", "World"]))
        await waitUntil(model.saveState == .rejected("disabledSources: at most 100 entries"))
        XCTAssertFalse(model.hasPendingSettings, "retrying can't help, so it isn't pending")
        await waitUntil(model.settings == account, "the phone shows what the account really has")
        XCTAssertEqual(attempts, 1)
        model.flushPendingSettings()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(attempts, 1, "not sent again")

        XCTAssertTrue(AppModel.isRejection(400))
        XCTAssertTrue(AppModel.isRejection(413))
        for code in [401, 408, 429, 500, 503] { XCTAssertFalse(AppModel.isRejection(code), "\(code)") }
    }

    func testAnExpiredSessionSignsOutWithAReason() async {
        model.sendSettings = { _, _ in throw APIError.unauthorized }
        LocalStore.onboarded = true
        model.update(with(["AI"]))
        await waitUntil(model.phase == .signedOut)
        XCTAssertEqual(model.accountError, "Your session ended. Please sign in again.")
        XCTAssertNil(model.sessionToken)
        XCTAssertFalse(model.hasPendingSettings)
    }

    func testAReinstallAdoptsTheAccountInsteadOfOnboarding() async throws {
        // The Keychain kept the session token; UserDefaults (onboarded, user id, settings) were wiped.
        var account = UserSettings.default
        account.categories = ["US", "Japan", "AI"]
        account.mutedWords = ["crypto"]
        account.boosts = ["nintendo"]
        var sent = 0
        model.sendSettings = { settings, _ in sent += 1; return settings }
        model.fetchAccount = { _ in AccountSnapshot(userID: "u1", settings: account) }
        let feed = try Fixture.feed()
        model.fetchFeed = { _ in .fresh(feed, data: feed.encoded, etag: nil) }
        var asked = false
        model.requestNotificationPermission = { asked = true; return false }

        await model.restore()
        XCTAssertEqual(model.phase, .ready, "no onboarding over an existing account")
        XCTAssertEqual(model.settings, account)
        XCTAssertTrue(LocalStore.onboarded)
        XCTAssertEqual(LocalStore.userID, "u1")
        XCTAssertEqual(sent, 0, "nothing was written over the account's settings")
        XCTAssertEqual(model.brief?.sections.map(\.name), ["US", "Japan", "AI"])
        XCTAssertTrue(asked, "notification permission doesn't survive a reinstall, so it's asked again")
    }

    func testAReinstallWhileOfflineAdoptsTheAccountOnceItArrives() async throws {
        var account = UserSettings.default
        account.categories = ["World"]
        account.mutedWords = ["crypto"]
        var sent = 0
        model.sendSettings = { settings, _ in sent += 1; return settings }
        var online = false
        model.fetchAccount = { _ in
            guard online else { throw URLError(.notConnectedToInternet) }
            return AccountSnapshot(userID: "u1", settings: account)
        }
        await model.restore()
        XCTAssertEqual(model.phase, .onboarding)
        XCTAssertEqual(model.settings, .default)

        online = true
        let feed = try Fixture.feed()
        model.fetchFeed = { _ in .fresh(feed, data: feed.encoded, etag: nil) }
        await model.refresh(reason: .user)
        await waitUntil(model.settings == account && model.phase == .ready,
                        "the account loaded: onboarding ends instead of offering to overwrite it")
        XCTAssertTrue(LocalStore.onboarded)
        XCTAssertEqual(sent, 0, "nothing was written over the account's settings")
    }

    func testFinishingOnboardingNeverOverwritesAnAccountThatHasntLoaded() async throws {
        model.fetchAccount = { _ in throw URLError(.notConnectedToInternet) }
        var sent = 0
        model.sendSettings = { settings, _ in sent += 1; return settings }
        await model.restore()
        XCTAssertEqual(model.phase, .onboarding)
        await model.finishOnboarding(with: .default)
        XCTAssertEqual(model.phase, .onboarding, "stays put until the account can be reached")
        XCTAssertEqual(sent, 0)
        XCTAssertNotNil(model.accountError)
    }

    func testAFreshSignUpStillOnboards() async {
        LocalStore.userID = "u1"  // set at sign-in
        await model.restore()
        XCTAssertEqual(model.phase, .onboarding)
    }

    func testSignedOutWithoutAToken() async {
        let signedOut = AppModel.forTesting(clock: clock, token: nil)
        await signedOut.restore()
        XCTAssertEqual(signedOut.phase, .signedOut)
        XCTAssertFalse(signedOut.isRestoringCache)
    }
}
