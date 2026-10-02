import Foundation

/// One person's brief for a day, built on the phone from the shared feed (see BriefBuilder).
/// Codable so past briefs can be kept on the device for the History tab.
struct Brief: Codable, Hashable, Sendable, Identifiable {
    let date: String          // local yyyy-MM-dd
    let generatedAt: Date
    let headline: String
    let top: [Story]
    let sections: [BriefSection]
    let sourceProblems: [String]
    var id: String { date }

    var allStories: [Story] { top + sections.flatMap(\.stories) }

    var displayDate: String {
        guard let day = Self.dayFormatter.date(from: date) else { return date }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

struct BriefSection: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let stories: [Story]
    var id: String { name }
}

struct Story: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let importance: Int
    /// CONFIRMED, REPORTED, RUMOR-CREDIBLE, RUMOR-UNVERIFIED or DEAL
    let label: String?
    let category: String
    let published: Date
    let outletCount: Int
    let sources: [Source]
}

struct Source: Codable, Hashable, Sendable, Identifiable {
    let outlet: String
    let title: String
    let url: URL
    let official: Bool
    var id: URL { url }
}
