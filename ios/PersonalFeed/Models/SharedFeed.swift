import Foundation

/// GET /v1/feed: the shared feed everyone downloads (built by `python -m briefing ingest`).
/// Each phone turns it into its owner's brief with `BriefBuilder`.
struct SharedFeed: Codable, Sendable {
    let version: Int
    let generatedAt: Date
    let windowHours: Int
    let sections: [String]
    let sources: [SourceInfo]
    let watchlist: [WatchRule]
    let stories: [FeedStory]
}

struct FeedStory: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let label: String
    let category: String
    let score: Double
    let official: Bool
    let trusted: Bool
    let outletCount: Int
    let published: Date
    let sources: [FeedSource]
    /// True when `summary` was written by AI from the outlets' headlines and snippets.
    var aiSummary: Bool?
}

struct FeedSource: Codable, Hashable, Sendable {
    let key: String
    let outlet: String
    let title: String
    let url: URL
    let official: Bool
    let published: Date
    /// Language code (e.g. "de") when the headline was machine-translated at ingest.
    var translatedFrom: String?
    var originalTitle: String?
}

/// One entry in the source catalog, used by the source pickers.
struct SourceInfo: Codable, Hashable, Sendable, Identifiable {
    let key: String
    let title: String
    let category: String
    let official: Bool
    let trusted: Bool
    let mirror: Bool
    let status: String
    let latest: Date?
    var id: String { key }
}

struct WatchRule: Codable, Hashable, Sendable {
    let name: String
    let match: [[String]]
}

extension JSONDecoder {
    /// The API speaks camelCase JSON with ISO-8601 dates.
    static let api: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let api: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
