import XCTest
@testable import PersonalFeed

/// shared-feed-fixture.json: real output of `python -m briefing ingest --dry-run`.
enum Fixture {
    private final class BundleToken {}

    static func data() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: BundleToken.self).url(forResource: "shared-feed-fixture", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    static func feed() throws -> SharedFeed {
        try JSONDecoder.api.decode(SharedFeed.self, from: data())
    }
}

extension SharedFeed {
    /// The same feed rebuilt `minutes` later with `extra` stories in front.
    func later(by minutes: Double, adding extra: [FeedStory] = []) -> SharedFeed {
        SharedFeed(version: version, generatedAt: generatedAt.addingTimeInterval(minutes * 60),
                   windowHours: windowHours, sections: sections, sources: sources, watchlist: watchlist,
                   stories: extra + stories)
    }

    var encoded: Data { (try? JSONEncoder.api.encode(self)) ?? Data() }
}

extension FeedStory {
    static func make(id: String, title: String, category: String = "Tech", label: String = "REPORTED",
                     score: Double = 50, published: Date, outlet: String = "The Verge", key: String = "verge",
                     url: String? = nil, summary: String = "") -> FeedStory {
        FeedStory(id: id, title: title, summary: summary, label: label, category: category, score: score,
                  official: false, trusted: false, outletCount: 1, published: published,
                  sources: [FeedSource(key: key, outlet: outlet, title: title,
                                       url: URL(string: url ?? "https://example.com/\(id)")!,
                                       official: false, published: published)])
    }
}

extension Story {
    static func make(id: String, title: String, category: String = "Tech", published: Date,
                     summary: String = "", label: String? = "REPORTED", sources: [Source] = []) -> Story {
        Story(id: id, title: title, summary: summary, importance: 1, label: label, category: category,
              published: published, outletCount: max(1, sources.count), sources: sources)
    }
}

extension TokenStore {
    static func memory(_ token: String?) -> TokenStore {
        TokenStore(load: { token }, save: { _ in }, delete: {})
    }
}

/// Points LocalStore at a throwaway UserDefaults suite and folder, so tests never touch the
/// simulator app's real data or each other's.
@MainActor
final class IsolatedStore {
    /// One suite, emptied before and after each test (tests run one at a time).
    let suite = "BriefTests"
    let defaults: UserDefaults
    let directory: URL
    private let previousDefaults: UserDefaults
    private let previousDirectory: URL

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        directory = FileManager.default.temporaryDirectory.appending(path: "BriefTests-\(UUID().uuidString)",
                                                                       directoryHint: .isDirectory)
        previousDefaults = LocalStore.defaults
        previousDirectory = LocalStore.directory
        LocalStore.defaults = defaults
        LocalStore.directory = directory
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        LocalStore.defaults = previousDefaults
        LocalStore.directory = previousDirectory
    }
}

/// A clock tests can move forward.
@MainActor
final class TestClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(minutes: Double) { now = now.addingTimeInterval(minutes * 60) }
}

@MainActor
extension AppModel {
    /// A model on the isolated store with no network: every dependency is a stub the test replaces.
    static func forTesting(clock: TestClock, token: String? = "test-token") -> AppModel {
        let model = AppModel()
        model.tokenStore = .memory(token)
        model.sessionToken = token
        model.clock = { clock.now }
        model.saveDelay = .zero
        model.historySaveDelay = .zero
        model.stateWriteDelay = .zero
        model.retryDelay = .zero
        model.fetchFeed = { _ in throw URLError(.notConnectedToInternet) }
        model.fetchAccount = { _ in throw URLError(.notConnectedToInternet) }
        model.sendSettings = { settings, _ in settings }
        model.requestNotificationPermission = { false }
        model.api = nil  // no account calls to the live Worker
        return model
    }
}

extension XCTestCase {
    /// Polls (yielding to other tasks) until `condition` holds or about two seconds pass.
    @MainActor
    func waitUntil(_ condition: @autoclosure () -> Bool, _ message: String = "",
                   file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }
}
