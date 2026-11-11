import Foundation

/// Something the reader did that says they care about a story. Swiping a story read without
/// opening it says nothing either way, so it isn't a signal.
enum InterestSignal: String, Codable, CaseIterable, Sendable {
    /// Opened the story's page.
    case opened
    /// Opened the article itself.
    case readArticle
    /// Saved it for later.
    case saved

    var weight: Double {
        switch self {
        case .opened: 1
        case .readArticle: 1.5
        case .saved: 2
        }
    }
}

/// What the reader reads most, learned on this phone from the stories they open, read and save:
/// topics, outlets and headline words. Old reading fades (a three-week half-life), so interests
/// can change. Never sent anywhere.
struct InterestProfile: Codable, Hashable, Sendable {
    static let halfLifeDays = 21.0
    static let maxTerms = 400
    static let maxOutlets = 150
    /// How long a story's signals are remembered, so reopening it doesn't count twice.
    static let countedMaxAge: TimeInterval = 4 * 24 * 3600

    var topics: [String: Double] = [:]
    var outlets: [String: Double] = [:]
    var terms: [String: Double] = [:]
    /// All signal weight recorded, faded like the rest: how much the profile has to go on.
    var total: Double = 0
    /// When the weights were last faded.
    var updatedAt: Date?
    /// "signal:storyID" → when it was counted.
    var counted: [String: Date] = [:]

    var isEmpty: Bool { total < 0.01 }

    /// Counts `signal` for `story` once; `outlet` is the outlet whose article was read, when it
    /// wasn't the lead. Returns false when this signal was already counted for the story.
    @discardableResult
    mutating func record(_ story: Story, _ signal: InterestSignal, outlet: String? = nil, now: Date) -> Bool {
        let key = "\(signal.rawValue):\(story.id)"
        guard counted[key] == nil else { return false }
        fade(to: now)
        let weight = signal.weight
        topics[story.category, default: 0] += weight
        let name = outlet ?? story.leadOutlet
        if !name.isEmpty { outlets[name, default: 0] += weight }
        let words = RelatedStories.words(in: story.title)
        if !words.isEmpty {
            // A long headline shouldn't count for more than a short one.
            let share = weight / Double(words.count).squareRoot()
            for word in words { terms[word, default: 0] += share }
        }
        total += weight
        counted[key] = now
        prune(now: now)
        return true
    }

    /// Fades every weight by the time since the last fade.
    mutating func fade(to now: Date) {
        guard let last = updatedAt else { updatedAt = now; return }
        guard now > last else { return }
        updatedAt = now
        let factor = pow(0.5, now.timeIntervalSince(last) / 86_400 / Self.halfLifeDays)
        guard factor < 0.9999 else { return }
        topics = topics.mapValues { $0 * factor }
        outlets = outlets.mapValues { $0 * factor }
        terms = terms.mapValues { $0 * factor }
        total *= factor
    }

    /// The most-read topics or outlets, heaviest first, for Settings.
    static func top(_ weights: [String: Double], _ count: Int) -> [String] {
        weights.filter { $0.value >= 0.5 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(count)
            .map(\.key)
    }

    private mutating func prune(now: Date) {
        topics = topics.filter { $0.value >= 0.01 }
        outlets = Self.heaviest(outlets.filter { $0.value >= 0.02 }, Self.maxOutlets)
        terms = Self.heaviest(terms.filter { $0.value >= 0.02 }, Self.maxTerms)
        counted = counted.filter { now.timeIntervalSince($0.value) <= Self.countedMaxAge }
    }

    private static func heaviest(_ weights: [String: Double], _ limit: Int) -> [String: Double] {
        guard weights.count > limit else { return weights }
        let kept = weights.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}

/// Turns an interest profile into a boost added to a story's feed score, so stories like the
/// ones the reader reads rank higher. Feed scores run from about 0 to 10 (20+ for a huge story),
/// so the boost (at most about 5.5) lifts a typical story the reader cares about toward the top
/// without burying the day's biggest news.
struct InterestScorer: Sendable {
    static let topicWeight = 2.5
    static let outletWeight = 1.0
    static let termWeight = 2.0
    /// Signal weight below which nothing is boosted: a couple of taps shouldn't reorder the feed.
    static let minimumSignal = 3.0
    /// Signal weight at which the profile counts in full (about eight articles read).
    static let fullConfidence = 12.0

    private let topicShare: [String: Double]
    private let outletShare: [String: Double]
    private let termShare: [String: Double]
    /// How rare each word is across today's headlines, 0 (in every one) to 1 (in one): "game"
    /// says little about a gaming reader, "Zelda" a lot.
    private let rarity: [String: Double]
    private let confidence: Double

    /// Nil until the profile has enough to go on. `titles` are the headlines being ranked.
    init?(profile: InterestProfile, titles: [String]) {
        guard profile.total >= Self.minimumSignal else { return nil }
        confidence = min(1, profile.total / Self.fullConfidence)
        let topicTotal = profile.topics.values.reduce(0, +)
        topicShare = topicTotal > 0 ? profile.topics.mapValues { $0 / topicTotal } : [:]
        let maxOutlet = profile.outlets.values.max() ?? 0
        outletShare = maxOutlet > 0 ? profile.outlets.mapValues { $0 / maxOutlet } : [:]
        let maxTerm = profile.terms.values.max() ?? 0
        termShare = maxTerm > 0 ? profile.terms.mapValues { $0 / maxTerm } : [:]

        var counts: [String: Int] = [:]
        for title in titles {
            for word in RelatedStories.words(in: title) where termShare[word] != nil { counts[word, default: 0] += 1 }
        }
        let n = Double(max(titles.count, 2))
        rarity = counts.mapValues { max(0, log(n / Double($0)) / log(n)) }
    }

    /// The boost for one story. `outlets` are its short outlet names (`Source.shortName`).
    func boost(title: String, category: String, outlets: [String]) -> Double {
        let topic = topicShare[category] ?? 0
        let outlet = outlets.map { outletShare[$0] ?? 0 }.max() ?? 0
        let words = RelatedStories.words(in: title)
        let match = words.reduce(0.0) { $0 + (termShare[$1] ?? 0) * (rarity[$1] ?? 1) }
        let raw = Self.topicWeight * topic + Self.outletWeight * outlet + Self.termWeight * min(1, match)
        return (confidence * raw * 100).rounded() / 100
    }
}
