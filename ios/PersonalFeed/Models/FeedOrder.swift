import Foundation

/// The "For you" order: stories you haven't got to yet, shuffled, then the ones you scrolled past,
/// then the ones you read. So each visit opens on different stories instead of the same top ten.
///
/// - Not yet seen: a weighted shuffle. Every story can land anywhere, but a higher score (more
///   outlets, official, fresher) and being new since your last visit tilt the odds toward the top,
///   so a big breaking story usually still shows up early. The shuffle is fixed by `seed`, so the
///   order holds still while you read and only changes when the seed does (a new visit or a pull
///   to refresh).
/// - Scrolled past: the ones skipped before this shuffle, shuffled the same way (so they don't come
///   back in the order you skipped them), then the ones skipped since, oldest first, so what you
///   skipped a moment ago is the last to come back around.
/// - Read: at the very bottom, the one read most recently last.
struct FeedOrder: Sendable {
    var seed: UInt64
    /// Story id → when it was read.
    var readAt: [String: Date] = [:]
    /// Story id → when it was scrolled past (only the marks already applied to the list).
    var passedAt: [String: Date] = [:]
    /// Story id → when this phone first saw it, with `newSince`: new stories get a nudge up.
    var firstSeen: [String: Date] = [:]
    var newSince: Date? = nil
    /// When `seed` was picked: stories passed before it are reshuffled, ones passed after aren't.
    var shuffledAt: Date? = nil

    /// How much the score tilts the shuffle: the odds of coming first grow by e (2.7×) for every
    /// `temperature` points. At 3, a story covered by five outlets is far likelier to be near the
    /// top than a one-outlet one, while stories of similar weight come out in a new order each time.
    static let temperature = 3.0
    /// What being new since the last visit is worth, in score points.
    static let newBoost = 3.0

    enum Tier: Int, Comparable, Sendable {
        case fresh, passed, read
        static func < (l: Tier, r: Tier) -> Bool { l.rawValue < r.rawValue }
    }

    func tier(of story: Story) -> Tier { tier(of: story.id) }

    func tier(of id: String) -> Tier {
        if readAt[id] != nil { return .read }
        if passedAt[id] != nil { return .passed }
        return .fresh
    }

    func isNew(_ story: Story) -> Bool {
        guard let newSince, let seen = firstSeen[story.id] else { return false }
        return seen > newSince
    }

    /// `stories` in For you order. Ties (which only the same seed and id could make) keep the
    /// incoming order.
    func apply(_ stories: [Story]) -> [Story] {
        var keyed: [Keyed] = []
        keyed.reserveCapacity(stories.count)
        for (offset, story) in stories.enumerated() {
            // Higher key first; for the time-ordered groups the key is minus the time, so the
            // oldest comes first.
            let entry: (group: Int, key: Double)
            switch tier(of: story) {
            case .fresh:
                entry = (0, shuffleKey(story))
            case .passed:
                let at = passedAt[story.id] ?? .distantPast
                if let shuffledAt, at >= shuffledAt {
                    entry = (2, -at.timeIntervalSinceReferenceDate)
                } else {
                    entry = (1, shuffleKey(story))
                }
            case .read:
                entry = (3, -(readAt[story.id] ?? .distantPast).timeIntervalSinceReferenceDate)
            }
            keyed.append(Keyed(group: entry.group, key: entry.key, offset: offset, story: story))
        }
        keyed.sort { l, r in
            if l.group != r.group { return l.group < r.group }
            if l.key != r.key { return l.key > r.key }
            return l.offset < r.offset
        }
        return keyed.map(\.story)
    }

    private struct Keyed {
        let group: Int
        let key: Double
        let offset: Int
        let story: Story
    }

    /// Sorting by score / temperature plus Gumbel noise is the same as drawing stories one at a
    /// time with odds proportional to e^(score / temperature).
    func shuffleKey(_ story: Story) -> Double {
        // Briefs saved before stories carried a score: outlet count, like the hot order.
        var score = story.score ?? Double(story.outletCount) * 3
        if isNew(story) { score += Self.newBoost }
        let u = Self.unitRandom(story.id, seed: seed)
        return score / Self.temperature - log(-log(u))
    }

    /// A number in (0, 1) fixed by the story id and the seed: the same pair always gives the same
    /// number, on any device (unlike Swift's Hasher, which changes every launch).
    static func unitRandom(_ id: String, seed: UInt64) -> Double {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed  // FNV-1a over the id, starting from the seed
        for byte in id.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        // SplitMix64's finalizer, so neighbouring ids and seeds don't give neighbouring numbers.
        h = (h ^ (h >> 30)) &* 0xbf58_476d_1ce4_e5b9
        h = (h ^ (h >> 27)) &* 0x94d0_49bb_1331_11eb
        h ^= h >> 31
        return (Double(h >> 11) + 0.5) / 9_007_199_254_740_992  // 2^53
    }
}
