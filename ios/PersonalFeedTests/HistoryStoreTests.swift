import XCTest
@testable import PersonalFeed

/// Past briefs: one file per day, written only when the day's brief changed, never replaced by an
/// empty or stale one, and migrated from the old single history.json without losing anything.
final class HistoryStoreTests: XCTestCase {
    private var feed: SharedFeed!
    private var directory: URL!
    private var legacy: URL!

    override func setUpWithError() throws {
        feed = try Fixture.feed()
        let root = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString)")
        directory = root.appending(path: "history", directoryHint: .isDirectory)
        legacy = root.appending(path: "history.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func store() -> HistoryStore { HistoryStore(directory: directory, legacyFile: legacy) }

    private func brief(_ settings: UserSettings = .default, hoursAfterFeed: Double = 1) -> Brief {
        BriefBuilder.build(feed: feed, settings: settings, now: feed.generatedAt.addingTimeInterval(hoursAfterFeed * 3600))
    }

    private var soon: Date { feed.generatedAt.addingTimeInterval(3600) }

    func testAnUnchangedBriefIsNotWrittenAgain() async throws {
        let history = store()
        let today = brief()
        let index = await history.save(today, now: soon)
        XCTAssertEqual(index?.map(\.date), [today.date])
        XCTAssertEqual(index?.first?.storyCount, today.storyCount)
        XCTAssertEqual(index?.first?.topTitle, today.top.first?.title)
        let unchanged = await history.save(today, now: soon.addingTimeInterval(600))
        XCTAssertNil(unchanged)
        var writes = await history.writeCount
        XCTAssertEqual(writes, 1)

        var more = UserSettings.default
        more.setCategory("US", enabled: true)
        more.mutedWords = ["anthropic"]
        let changed = brief(more)
        let resaved = await history.save(changed, now: soon)
        XCTAssertNotNil(resaved)
        writes = await history.writeCount
        XCTAssertEqual(writes, 2)
        let loaded = await history.loadBrief(date: today.date)
        XCTAssertEqual(loaded, changed)
    }

    func testAnEmptyOrStaleBriefNeverReplacesAGoodDay() async throws {
        let history = store()
        let today = brief()
        _ = await history.save(today, now: soon)

        var nothing = UserSettings.default
        nothing.disabledSources = Array(Set(feed.stories.flatMap { $0.sources.map(\.key) }))
        let empty = brief(nothing)
        XCTAssertEqual(empty.storyCount, 0)
        XCTAssertEqual(empty.date, today.date)
        let afterEmpty = await history.save(empty, now: soon)
        XCTAssertNil(afterEmpty, "an empty brief doesn't overwrite the day")

        // Offline with a cache more than a day old: not a snapshot of anything new.
        let staleNow = feed.generatedAt.addingTimeInterval(25 * 3600)
        let stale = BriefBuilder.build(feed: feed, settings: .default, now: staleNow)
        let afterStale = await history.save(stale, now: staleNow)
        XCTAssertNil(afterStale)
        let writes = await history.writeCount
        XCTAssertEqual(writes, 1)
        let kept = await history.loadBrief(date: today.date)
        XCTAssertEqual(kept, today)
    }

    func testTheIndexSurvivesARelaunchAndOldDaysArePruned() async throws {
        let first = store()
        let today = brief()
        _ = await first.save(today, now: soon)
        let relaunched = store()
        let index = await relaunched.loadIndex(now: soon)
        XCTAssertEqual(index.map(\.date), [today.date])
        XCTAssertNotNil(index.first?.signature)

        let monthLater = await store().loadIndex(now: soon.addingTimeInterval(31 * 24 * 3600))
        XCTAssertTrue(monthLater.isEmpty, "days older than 30 are dropped")
        let gone = await store().loadBrief(date: today.date)
        XCTAssertNil(gone, "with their files")
    }

    func testAnUnreadableIndexIsRebuiltFromTheDayFiles() async throws {
        let today = brief()
        _ = await store().save(today, now: soon)
        try Data(#"{"not":"an array"}"#.utf8).write(to: directory.appending(path: "index.json"))
        let reopened = await store().loadIndex(now: soon)
        XCTAssertEqual(reopened.map(\.date), [today.date], "the day is still listed")
    }

    func testTheOldSingleFileIsSplitIntoDays() async throws {
        let today = brief()
        let yesterday = BriefBuilder.build(feed: feed, settings: .default, now: feed.generatedAt.addingTimeInterval(-30 * 3600))
        XCTAssertNotEqual(today.date, yesterday.date)
        try JSONEncoder.api.encode([today, yesterday]).write(to: legacy)

        let history = store()
        let index = await history.loadIndex(now: soon)
        XCTAssertEqual(index.map(\.date), [today.date, yesterday.date], "newest first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "removed once every day was written")
        let loadedYesterday = await history.loadBrief(date: yesterday.date)
        XCTAssertEqual(loadedYesterday, yesterday)
        // Migrated days aren't rewritten when the same brief is saved again.
        let resave = await history.save(today, now: soon)
        XCTAssertNil(resave)
    }

    func testAnUnreadableOldFileIsKept() async throws {
        try Data("not json".utf8).write(to: legacy)
        let index = await store().loadIndex(now: soon)
        XCTAssertTrue(index.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "never deleted unless split")
    }

    func testSignatureFollowsWhatTheBriefShows() {
        let a = brief()
        XCTAssertEqual(HistoryStore.signature(of: a), HistoryStore.signature(of: brief(hoursAfterFeed: 2)))
        var s = UserSettings.default
        s.categories = ["AI", "Gaming"]
        XCTAssertNotEqual(HistoryStore.signature(of: a), HistoryStore.signature(of: brief(s)))
    }
}

/// Read marks and first-seen marks: pruned by age, never at random.
final class ReadingStateTests: XCTestCase {
    func testReadPruningDropsTheOldestNeverTheNewest() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var reads: [String: Date] = [:]
        for i in 0...ReadingState.readCap { reads["s\(i)"] = now.addingTimeInterval(Double(i - ReadingState.readCap) * 60) }
        reads["ancient"] = now.addingTimeInterval(-40 * 24 * 3600)
        let pruned = ReadingState.prunedReads(reads, now: now)
        XCTAssertEqual(pruned.count, ReadingState.readCap)
        XCTAssertNotNil(pruned["s\(ReadingState.readCap)"], "the story read just now survives")
        XCTAssertNil(pruned["s0"], "the oldest goes first")
        XCTAssertNil(pruned["ancient"], "reads older than 35 days go")

        let few = ["a": now.addingTimeInterval(-34 * 24 * 3600), "b": now]
        XCTAssertEqual(ReadingState.prunedReads(few, now: now), few)
    }

    func testFirstSeenIsSeededOnFirstRunAndPrunedAfterThreeDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let seeded = ReadingState.recordingFirstSeen([:], ids: ["a", "b"], now: now, seenBefore: false)
        XCTAssertEqual(seeded, ["a": ReadingState.seeded, "b": ReadingState.seeded])
        let later = ReadingState.recordingFirstSeen(seeded, ids: ["a", "c"], now: now, seenBefore: true)
        XCTAssertEqual(later["a"], ReadingState.seeded, "first seen never moves")
        XCTAssertEqual(later["c"], now)

        let marks = ["inFeed": ReadingState.seeded, "gone": now.addingTimeInterval(-73 * 3600),
                     "recent": now.addingTimeInterval(-3600)]
        XCTAssertEqual(Set(ReadingState.prunedFirstSeen(marks, feedIDs: ["inFeed"], now: now).keys), ["inFeed", "recent"])
    }
}
