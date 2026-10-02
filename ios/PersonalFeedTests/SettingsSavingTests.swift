import XCTest
@testable import PersonalFeed

/// Topic choices must survive slow, overlapping and failing saves.
@MainActor
final class SettingsSavingTests: XCTestCase {
    private var model: AppModel!

    override func setUp() async throws {
        LocalStore.settingsPending = false
        model = AppModel()
        model.sessionToken = "test-token"
        model.saveDelay = .zero
    }

    override func tearDown() async throws {
        LocalStore.settingsPending = false
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, _ message: String = "") async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), message)
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
}
