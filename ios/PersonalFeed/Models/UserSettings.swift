import Foundation

/// A user's preferences. Same JSON shape as server/src/settings.js, which validates it and
/// stores it with their account, so it follows them to any device they sign in on.
struct UserSettings: Codable, Hashable, Sendable {
    var version = 1
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

    /// Display order for topics and source groups; matches CATEGORIES in server/src/settings.js.
    static let allCategories = ["AI", "Tech", "Gaming", "US", "World", "Europe", "Japan", "Korea", "Deals"]
    /// What a new account starts with. US, World, Europe, Japan and Korea are opt-in.
    static let defaultCategories = ["AI", "Tech", "Gaming", "Deals"]
    static let `default` = UserSettings()

    func isSourceEnabled(_ key: String) -> Bool { !disabledSources.contains(key) }

    mutating func setSource(_ key: String, enabled: Bool) {
        disabledSources.removeAll { $0 == key }
        if !enabled { disabledSources.append(key) }
    }

    mutating func setCategory(_ name: String, enabled: Bool) {
        categories.removeAll { $0 == name }
        if enabled {
            categories.append(name)
            categories.sort { (Self.allCategories.firstIndex(of: $0) ?? 99) < (Self.allCategories.firstIndex(of: $1) ?? 99) }
        }
    }
}
