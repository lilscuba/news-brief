import Foundation

/// Small on-device persistence: preferences in UserDefaults, the cached feed and reading state as
/// JSON files in Application Support. Past briefs live in `HistoryStore`.
///
/// `defaults` and `directory` are swapped by tests and the DEBUG demo mode so they never touch the
/// real store.
enum LocalStore {
    static let historyDays = 30
    static var defaults: UserDefaults = .standard
    static var directory: URL = URL.applicationSupportDirectory

    /// Files written next to feed.json.
    enum File: String, CaseIterable, Sendable {
        case feed = "feed.json"
        case read = "read.json"
        case seen = "seen.json"
        case saved = "saved.json"
        case recent = "recent.json"
    }

    // MARK: UserDefaults

    static var onboarded: Bool {
        get { defaults.bool(forKey: "onboarded") }
        set { defaults.set(newValue, forKey: "onboarded") }
    }

    /// Settings changed on this phone that the account hasn't confirmed yet.
    static var settingsPending: Bool {
        get { defaults.bool(forKey: "settingsPending") }
        set { defaults.set(newValue, forKey: "settingsPending") }
    }

    static var userID: String? {
        get { defaults.string(forKey: "userID") }
        set { defaults.set(newValue, forKey: "userID") }
    }

    static var settings: UserSettings? {
        get { defaults.data(forKey: "settings").flatMap { try? JSONDecoder.api.decode(UserSettings.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder.api.encode($0) }, forKey: "settings") }
    }

    /// The ETag of the cached feed.json, so a cold launch can ask "anything newer?" (304) instead
    /// of downloading the whole feed again. Only written after feed.json is.
    static var feedETag: String? {
        get { defaults.string(forKey: feedETagKey) }
        set { defaults.set(newValue, forKey: feedETagKey) }
    }
    static let feedETagKey = "feedETag"

    /// When the phone last heard back from the feed (200 or 304).
    static var feedCheckedAt: Date? {
        get { defaults.object(forKey: "feedCheckedAt") as? Date }
        set { defaults.set(newValue, forKey: "feedCheckedAt") }
    }

    /// When the reader last left the app after really using it (10+ seconds in the foreground).
    /// Background refreshes never move it.
    static var lastVisitAt: Date? {
        get { defaults.object(forKey: "lastVisitAt") as? Date }
        set { defaults.set(newValue, forKey: "lastVisitAt") }
    }

    /// The APNs token, kept so Sign out can unregister this phone after a relaunch.
    static var deviceToken: String? {
        get { defaults.string(forKey: "deviceToken") }
        set { defaults.set(newValue, forKey: "deviceToken") }
    }

    /// Read state from builds before read.json: an unordered list of ids. Left in place (a
    /// downgrade still finds it) and only read when read.json doesn't exist yet.
    static var legacyReadIDs: [String]? { defaults.stringArray(forKey: "readIDs") }

    static func resetForNewUser(_ id: String?) {
        userID = id
        onboarded = false
        lastVisitAt = nil
        defaults.removeObject(forKey: "readIDs")
        defaults.removeObject(forKey: RecentSearches.storageKey)  // searches belong to the account too
        for file in File.allCases where file != .feed { remove(file) }
        try? FileManager.default.removeItem(at: historyDirectory)
        try? FileManager.default.removeItem(at: legacyHistoryFile)
    }

    // MARK: Files

    static var historyDirectory: URL { directory.appending(path: "history", directoryHint: .isDirectory) }
    /// The single-file history of older builds, split into per-day files on first launch.
    static var legacyHistoryFile: URL { directory.appending(path: "history.json") }

    static func url(_ file: File) -> URL { directory.appending(path: file.rawValue) }

    @discardableResult
    static func saveFeed(_ data: Data) -> Bool { write(data, to: url(.feed)) }

    static func loadFeed() -> SharedFeed? {
        read(url(.feed)).flatMap { try? JSONDecoder.api.decode(SharedFeed.self, from: $0) }
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T, _ file: File) -> Bool {
        guard let data = try? JSONEncoder.api.encode(value) else { return false }
        return write(data, to: url(file))
    }

    /// Nil when the file is missing; a file that exists but can't be decoded is moved aside rather
    /// than silently treated as empty and overwritten.
    static func load<T: Decodable>(_ type: T.Type, _ file: File) -> T? {
        guard let data = read(url(file)) else { return nil }
        if let value = try? JSONDecoder.api.decode(type, from: data) { return value }
        let aside = url(file).deletingPathExtension().appendingPathExtension("unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url(file), to: aside)
        return nil
    }

    static func exists(_ file: File) -> Bool { FileManager.default.fileExists(atPath: url(file).path) }

    static func remove(_ file: File) { try? FileManager.default.removeItem(at: url(file)) }

    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}

/// Pure rules for the reading-state maps, kept apart from AppModel so they can be tested.
enum ReadingState {
    /// Read marks outlive the 30-day Past briefs.
    static let readMaxAge: TimeInterval = 35 * 24 * 3600
    static let readCap = 5_000
    /// "First seen" marks only matter while a story can still be in the 48 h feed.
    static let seenMaxAge: TimeInterval = 72 * 3600
    /// What a story is stamped with when the phone first meets it without a previous visit to
    /// compare against (first run or an upgrade), so day one doesn't show 900 "new" stories.
    static let seeded = Date(timeIntervalSince1970: 0)
    static let recentCap = 50

    /// Drops reads older than 35 days, then the oldest ones while over the cap. Never at random.
    static func prunedReads(_ reads: [String: Date], now: Date) -> [String: Date] {
        var kept = reads.filter { now.timeIntervalSince($0.value) <= readMaxAge }
        if kept.count > readCap {
            let newest = kept.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(readCap)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        return kept
    }

    /// Stamps every story the phone hasn't met before. With no history at all (`seenBefore` is
    /// false) they're stamped `seeded` rather than now.
    static func recordingFirstSeen(_ seen: [String: Date], ids: [String], now: Date,
                                   seenBefore: Bool) -> [String: Date] {
        var out = seen
        let stamp = seenBefore ? now : seeded
        for id in ids where out[id] == nil { out[id] = stamp }
        return out
    }

    /// Keeps marks for stories still in the feed, plus anything stamped in the last 72 h.
    static func prunedFirstSeen(_ seen: [String: Date], feedIDs: Set<String>, now: Date) -> [String: Date] {
        seen.filter { feedIDs.contains($0.key) || now.timeIntervalSince($0.value) <= seenMaxAge }
    }
}

/// A story kept for later. The whole story is stored so it stays readable after it leaves the feed.
struct SavedStory: Codable, Hashable, Sendable, Identifiable {
    let story: Story
    let savedAt: Date
    var id: String { story.id }
}

/// A story the reader opened (its page or its article), for "Recently read".
struct RecentStory: Codable, Hashable, Sendable, Identifiable {
    let story: Story
    let openedAt: Date
    var id: String { story.id }
}
