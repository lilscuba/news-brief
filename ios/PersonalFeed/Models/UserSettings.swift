import Foundation

/// A user's preferences. Same JSON shape as server/src/settings.js, which validates it and
/// stores it with their account, so it follows them to any device they sign in on.
struct UserSettings: Codable, Hashable, Sendable {
    var version = 1
    /// Followed topics in the reader's order; Today's sections follow it.
    var categories: [String] = UserSettings.defaultCategories
    var disabledSources: [String] = []
    var mutedWords: [String] = []
    var boosts: [String] = []
    var alerts = Alerts()
    var brief = BriefPrefs()

    struct Alerts: Codable, Hashable, Sendable {
        var official = true       // tier 1: first-party lab posts
        var trusted = true        // tier 2: a proven scoop source matches your watchlist
        var corroborated = true   // tier 3: 2+ outlets match your watchlist
        var defaultWatchlist = true
        var keywords: [String] = []
        var maxPerDay = 5
    }

    struct BriefPrefs: Codable, Hashable, Sendable {
        var notify = true
        var hour = 7
        var timezone = TimeZone.current.identifier
    }

    /// Catalog order for topics and source groups; matches CATEGORIES in server/src/settings.js.
    static let allCategories = ["AI", "Tech", "Gaming", "US", "World", "Europe", "Japan", "Korea", "Deals"]
    /// What a new account starts with. US, World, Europe, Japan and Korea are opt-in.
    static let defaultCategories = ["AI", "Tech", "Gaming", "Deals"]
    /// The server's limit for muted words, boosts and keywords (server/src/settings.js MAX_LIST).
    static let maxTerms = 100
    static let `default` = UserSettings()

    /// Topics not followed, in catalog order.
    var unfollowedCategories: [String] { Self.allCategories.filter { !categories.contains($0) } }

    func isSourceEnabled(_ key: String) -> Bool { !disabledSources.contains(key) }

    mutating func setSource(_ key: String, enabled: Bool) {
        disabledSources.removeAll { $0 == key }
        if !enabled { disabledSources.append(key) }
    }

    /// Following a topic adds it at the end, so the reader's own order is kept.
    mutating func setCategory(_ name: String, enabled: Bool) {
        if enabled {
            if !categories.contains(name) { categories.append(name) }
        } else {
            categories.removeAll { $0 == name }
        }
    }

    /// Same contract as SwiftUI's `onMove` (offsets in the current list, destination before the move).
    mutating func moveCategories(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.filter { categories.indices.contains($0) }.map { categories[$0] }
        var rest = categories
        for i in source.sorted(by: >) where rest.indices.contains(i) { rest.remove(at: i) }
        let at = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(at, rest.count)))
        categories = rest
    }

    /// The parts BriefBuilder reads. Alert and morning-brief edits don't change the brief, so they
    /// don't need a rebuild.
    var briefKey: BriefKey { BriefKey(categories: categories, disabledSources: disabledSources,
                                      mutedWords: mutedWords, boosts: boosts) }

    struct BriefKey: Hashable, Sendable {
        let categories: [String]
        let disabledSources: [String]
        let mutedWords: [String]
        let boosts: [String]
    }
}
