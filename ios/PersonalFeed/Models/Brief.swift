import Foundation

/// One person's brief for a day, built on the phone from the shared feed (see BriefBuilder).
/// Codable so past briefs can be kept on the device for Past briefs. Every field added after the
/// first release is optional, so briefs saved by older builds still decode.
struct Brief: Codable, Hashable, Sendable, Identifiable {
    let date: String          // local yyyy-MM-dd
    let generatedAt: Date
    /// "N stories from M sources". Kept for briefs saved by older builds; newer views can format
    /// `storyCount` and `sourceCount` themselves.
    let headline: String
    let top: [Story]
    /// One per followed topic, in the reader's order. A story promoted to `top` is not repeated
    /// here, so Today never shows it twice; `stories(inTopic:)` puts it back for topic pages.
    let sections: [BriefSection]
    let sourceProblems: [String]
    /// Enabled sources in followed topics (nil in briefs saved by older builds).
    var sourceCount: Int? = nil
    /// Hours of news covered: 24, or more when catching up after a long absence.
    var windowHours: Int? = nil
    var id: String { date }

    /// Top stories first, then every section. No story appears twice.
    var allStories: [Story] {
        var seen = Set<String>()
        return (top + sections.flatMap(\.stories)).filter { seen.insert($0.id).inserted }
    }

    /// Unique stories in the brief (what the headline counts).
    var storyCount: Int { Set(top.map(\.id) + sections.flatMap { $0.stories.map(\.id) }).count }

    /// Every story of one topic, including the ones promoted to Top stories, in hot order.
    /// Top stories outscore everything left in the sections, so putting them first keeps the order.
    func stories(inTopic name: String) -> [Story] {
        let promoted = top.filter { $0.category == name }
        let rest = sections.first { $0.name == name }?.stories ?? []
        let promotedIDs = Set(promoted.map(\.id))
        return promoted + rest.filter { !promotedIDs.contains($0.id) }
    }

    /// Followed topics that have at least one story, counting the ones in Top stories.
    var topicsWithStories: [String] {
        sections.map(\.name).filter { !stories(inTopic: $0).isEmpty }
    }

    /// Followed topics with nothing in them right now.
    var quietTopics: [String] {
        sections.map(\.name).filter { stories(inTopic: $0).isEmpty }
    }

    /// Every story ordered by score across topics (falls back to the brief's own order for
    /// briefs saved before scores were kept).
    var allStoriesByScore: [Story] {
        allStories.enumerated().sorted { l, r in
            let a = l.element.score ?? -Double(l.offset), b = r.element.score ?? -Double(r.offset)
            return a != b ? a > b : l.offset < r.offset
        }.map(\.element)
    }

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

    /// The local yyyy-MM-dd day of `date`, the key briefs are stored under.
    static func day(of date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
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
    /// CONFIRMED, REPORTED, RUMOR-CREDIBLE, RUMOR-UNVERIFIED or DEAL (see `reliability`).
    let label: String?
    let category: String
    /// When the newest source published, so it moves forward as coverage grows. See `firstReported`.
    let published: Date
    let outletCount: Int
    /// The first source is the story's headline and its "Read article" target.
    let sources: [Source]
    var aiSummary: Bool?
    /// True for an opinion or editorial piece.
    var opinion: Bool? = nil
    /// Feed score plus the reader's boosts; orders stories across topics. Nil in old briefs.
    var score: Double? = nil

    /// The headline comes from the first source (see `_story` in briefing/service.py).
    var isTranslated: Bool { sources.first?.translatedFrom != nil }

    var isOpinion: Bool { opinion == true }

    /// Short name of the outlet the headline and "Read article" come from, e.g. "Hacker News".
    var leadOutlet: String { sources.first?.shortOutlet ?? "" }

    /// When the earliest source published. Older briefs have no per-source times, so this falls
    /// back to `published`.
    var firstReported: Date { sources.compactMap(\.published).min() ?? published }

    var reliability: ReliabilityLabel? { label.flatMap(ReliabilityLabel.init(rawValue:)) }

    /// The label worth showing: everything except the default REPORTED.
    var notableReliability: ReliabilityLabel? { reliability.flatMap { $0.isNotable ? $0 : nil } }

    /// Distinct outlets, in source order (the lead first).
    var outlets: [String] {
        var seen = Set<String>()
        return sources.map(\.shortOutlet).filter { seen.insert($0).inserted }
    }

    /// False when there's no summary, or it only repeats the headline.
    var hasUsefulSummary: Bool { SummaryCheck.isUseful(summary, title: title) }
}

struct Source: Codable, Hashable, Sendable, Identifiable {
    let outlet: String
    let title: String
    let url: URL
    let official: Bool
    /// Language code (e.g. "de") when the headline was machine-translated; `originalTitle` is the
    /// untranslated headline.
    var translatedFrom: String?
    var originalTitle: String?
    /// When this outlet published (nil in briefs saved by older builds).
    var published: Date? = nil
    /// Catalog key, for "hide this source" (nil in older briefs).
    var key: String? = nil
    var id: URL { url }

    /// "Hacker News (100+ points)" → "Hacker News", "The Wall Street Journal: U.S." → "The Wall
    /// Street Journal". Catalog names carry a region or section that rows don't need.
    var shortOutlet: String { Self.shortName(outlet) }

    static func shortName(_ outlet: String) -> String {
        var name = outlet.trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            name = String(name[..<open.lowerBound])
        }
        if let colon = name.range(of: ": ") {
            let head = String(name[..<colon.lowerBound])
            if !head.isEmpty { name = head }
        }
        return aliases[name] ?? name
    }

    private static let aliases = ["HN": "Hacker News"]
}

/// The pipeline's reliability label, so a rumor never reads like a confirmed announcement.
enum ReliabilityLabel: String, CaseIterable, Sendable {
    case confirmed = "CONFIRMED"
    case reported = "REPORTED"
    case credibleRumor = "RUMOR-CREDIBLE"
    case unverifiedRumor = "RUMOR-UNVERIFIED"
    case deal = "DEAL"

    var displayName: String {
        switch self {
        case .confirmed: "Confirmed"
        case .reported: "Reported"
        case .credibleRumor: "Credible rumor"
        case .unverifiedRumor: "Unverified rumor"
        case .deal: "Deal"
        }
    }

    /// What VoiceOver says before the headline.
    var spokenText: String {
        switch self {
        case .confirmed: "Confirmed"
        case .reported: "Reported"
        case .credibleRumor: "Credible rumor"
        case .unverifiedRumor: "Unverified rumor, not confirmed"
        case .deal: "Deal"
        }
    }

    var systemImage: String {
        switch self {
        case .confirmed: "checkmark.seal.fill"
        case .reported: "newspaper"
        case .credibleRumor, .unverifiedRumor: "exclamationmark.triangle.fill"
        case .deal: "tag.fill"
        }
    }

    var isRumor: Bool { self == .credibleRumor || self == .unverifiedRumor }

    /// REPORTED is what almost every story is, so it isn't worth a badge.
    var isNotable: Bool { self != .reported }
}

/// Decides whether a summary adds anything to its headline.
enum SummaryCheck {
    static func isUseful(_ summary: String, title: String) -> Bool {
        let s = words(summary), t = words(title)
        guard !s.isEmpty else { return false }
        let sj = s.joined(separator: " "), tj = t.joined(separator: " ")
        if sj == tj || tj.contains(sj) { return false }
        // Headline plus a little more is still mostly a repeat.
        if sj.hasPrefix(tj) { return sj.count - tj.count >= 40 }
        let titleWords = Set(t)
        let shared = s.filter { titleWords.contains($0) }.count
        return !(Double(shared) / Double(s.count) >= 0.8 && s.count <= t.count + 3)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }
}
