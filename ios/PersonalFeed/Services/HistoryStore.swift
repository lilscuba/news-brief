import Foundation

/// One line of Past briefs: enough to list a day without decoding its whole brief.
struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    let date: String          // local yyyy-MM-dd, same as Brief.date
    let headline: String
    /// The day's lead story, shown under the date.
    let topTitle: String?
    let storyCount: Int
    var generatedAt: Date? = nil
    /// Fingerprint of the stored brief, so an unchanged brief is never written again.
    var signature: String? = nil
    var id: String { date }

    var displayDate: String {
        guard let day = Brief.dayFormatter.date(from: date) else { return date }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

/// Past briefs on disk, one file per day plus a small index, all handled off the main thread.
/// Only today's file is ever rewritten, and only when its content changed: re-encoding 30 days of
/// briefs on every refresh used to stall the UI for 100-200 ms.
actor HistoryStore {
    let directory: URL
    private let legacyFile: URL
    private let keepDays: Int
    private var index: [HistoryEntry]?
    /// Number of day files written; lets tests check that unchanged briefs aren't rewritten.
    private(set) var writeCount = 0

    init(directory: URL = LocalStore.historyDirectory, legacyFile: URL = LocalStore.legacyHistoryFile,
         keepDays: Int = LocalStore.historyDays) {
        self.directory = directory
        self.legacyFile = legacyFile
        self.keepDays = keepDays
    }

    /// The index, newest first. Splits an old history.json on first use and prunes days older
    /// than `keepDays`.
    func loadIndex(now: Date = .now) -> [HistoryEntry] {
        if let index { return index }
        var entries: [HistoryEntry]
        if let data = LocalStore.read(indexURL) {
            if let decoded = try? JSONDecoder.api.decode([HistoryEntry].self, from: data) {
                entries = decoded
            } else {
                // An unreadable index mustn't hide every past brief: list the day files again.
                entries = rebuildIndex()
            }
        } else {
            entries = []
        }
        if FileManager.default.fileExists(atPath: legacyFile.path) {
            entries = migrateLegacy(into: entries)
        }
        entries = prune(entries, now: now)
        index = entries
        return entries
    }

    func loadBrief(date: String) -> Brief? {
        LocalStore.read(fileURL(date)).flatMap { try? JSONDecoder.api.decode(Brief.self, from: $0) }
    }

    /// Stores `brief` as its day's snapshot. Returns the new index, or nil when nothing was written:
    /// the content is unchanged, an empty brief would replace a non-empty one, or the feed it was
    /// built from is more than a day old (an offline phone with a stale cache).
    func save(_ brief: Brief, now: Date = .now) -> [HistoryEntry]? {
        var entries = loadIndex(now: now)
        guard now.timeIntervalSince(brief.generatedAt) <= 24 * 3600 else { return nil }
        let signature = Self.signature(of: brief)
        let existing = entries.first { $0.date == brief.date }
        if existing?.signature == signature { return nil }
        if let existing, existing.storyCount > 0, brief.storyCount == 0 { return nil }
        guard let data = try? JSONEncoder.api.encode(brief), LocalStore.write(data, to: fileURL(brief.date))
        else { return nil }
        writeCount += 1
        entries.removeAll { $0.date == brief.date }
        entries.append(Self.entry(for: brief, signature: signature))
        entries = prune(entries, now: now)
        writeIndex(entries)
        index = entries
        return entries
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        index = []
    }

    // MARK: Plumbing

    private var indexURL: URL { directory.appending(path: "index.json") }
    private func fileURL(_ date: String) -> URL { directory.appending(path: "\(date).json") }

    private func writeIndex(_ entries: [HistoryEntry]) {
        if let data = try? JSONEncoder.api.encode(entries) { LocalStore.write(data, to: indexURL) }
    }

    /// Newest first, at most `keepDays` days back; older day files are deleted.
    private func prune(_ entries: [HistoryEntry], now: Date) -> [HistoryEntry] {
        let cutoff = Brief.day(of: now.addingTimeInterval(-Double(keepDays) * 24 * 3600))
        let sorted = entries.sorted { $0.date > $1.date }
        for old in sorted where old.date < cutoff {
            try? FileManager.default.removeItem(at: fileURL(old.date))
        }
        return sorted.filter { $0.date >= cutoff }
    }

    /// Splits the old single history.json into day files. The old file is only deleted once every
    /// day and the index were written; if anything fails it stays and the split is retried next launch.
    private func migrateLegacy(into entries: [HistoryEntry]) -> [HistoryEntry] {
        guard let data = LocalStore.read(legacyFile),
              let briefs = try? JSONDecoder.api.decode([Brief].self, from: data)
        else { return entries }
        var merged = entries
        var allWritten = true
        for brief in briefs where !merged.contains(where: { $0.date == brief.date }) {
            let signature = Self.signature(of: brief)
            if let day = try? JSONEncoder.api.encode(brief), LocalStore.write(day, to: fileURL(brief.date)) {
                merged.append(Self.entry(for: brief, signature: signature))
            } else {
                allWritten = false
            }
        }
        merged.sort { $0.date > $1.date }
        if allWritten, let indexData = try? JSONEncoder.api.encode(merged), LocalStore.write(indexData, to: indexURL) {
            try? FileManager.default.removeItem(at: legacyFile)
        }
        return merged
    }

    /// The index rebuilt from the yyyy-MM-dd.json day files, newest first.
    private func rebuildIndex() -> [HistoryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let entries = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
            .compactMap { url in
                LocalStore.read(url).flatMap { try? JSONDecoder.api.decode(Brief.self, from: $0) }
            }
            .map { Self.entry(for: $0, signature: Self.signature(of: $0)) }
            .sorted { $0.date > $1.date }
        writeIndex(entries)
        return entries
    }

    static func entry(for brief: Brief, signature: String) -> HistoryEntry {
        HistoryEntry(date: brief.date, headline: brief.headline,
                     topTitle: brief.top.first?.title ?? brief.allStories.first?.title,
                     storyCount: brief.storyCount, generatedAt: brief.generatedAt, signature: signature)
    }

    /// A stable fingerprint (FNV-1a) of what the brief shows: feed time, headline and story order.
    static func signature(of brief: Brief) -> String {
        var text = "\(brief.generatedAt.timeIntervalSince1970)|\(brief.headline)|"
        text += brief.top.map(\.id).joined(separator: ",")
        for section in brief.sections {
            text += "|\(section.name):" + section.stories.map(\.id).joined(separator: ",")
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
