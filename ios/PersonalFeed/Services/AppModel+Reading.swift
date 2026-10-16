import Foundation

/// Reading state, all on this phone: what's been read, what's new since the last visit, saved
/// stories and recently read. Each is a small JSON file in Application Support, written off the
/// main thread a second after the last change (and when the app goes to the background).
extension AppModel {
    // MARK: Read

    func isRead(_ story: Story) -> Bool { readAt[story.id] != nil }

    func setRead(_ story: Story, _ read: Bool) {
        setRead([story], read)
    }

    func setRead(_ stories: [Story], _ read: Bool) {
        let at = now()
        var changed = false
        for story in stories {
            if read, readAt[story.id] == nil {
                readAt[story.id] = at
                changed = true
            } else if !read, readAt.removeValue(forKey: story.id) != nil {
                changed = true
            }
        }
        guard changed else { return }
        if readAt.count > ReadingState.readCap { readAt = ReadingState.prunedReads(readAt, now: at) }
        scheduleWrite(.read)
    }

    func markRead(_ story: Story) { setRead(story, true) }

    /// Marks every story read and returns the ones that weren't, so "Mark all as read" can be undone
    /// with `setRead(returned, false)`.
    @discardableResult
    func markRead(_ stories: [Story]) -> [Story] {
        let unread = stories.filter { !isRead($0) }
        setRead(unread, true)
        return unread
    }

    func toggleRead(_ story: Story) { setRead(story, !isRead(story)) }

    /// The reader opened a story's page or its article: mark it read and remember it under
    /// Recently read.
    func noteOpened(_ story: Story) {
        setRead(story, true)
        recent.removeAll { $0.id == story.id }
        recent.insert(RecentStory(story: story, openedAt: now()), at: 0)
        if recent.count > ReadingState.recentCap { recent.removeLast(recent.count - ReadingState.recentCap) }
        scheduleWrite(.recent)
    }

    func clearRecent() {
        recent = []
        scheduleWrite(.recent)
    }

    // MARK: New since the last visit

    /// Unread and first seen on this phone after the reader's previous visit ended.
    func isNew(_ story: Story) -> Bool {
        guard let since = previousVisitAt, let seen = firstSeen[story.id] else { return false }
        return seen > since && !isRead(story)
    }

    /// Today's new stories, in hot order across topics.
    var newStories: [Story] { (brief?.allStoriesByScore ?? []).filter(isNew) }

    /// When the previous visit ended, for "N new since 9:40 AM". Nil when there's nothing new.
    var newSince: Date? { newStories.isEmpty ? nil : previousVisitAt }

    /// New, unread stories in one of today's topics.
    func newCount(inTopic name: String) -> Int { stories(inTopic: name).filter(isNew).count }

    func unreadCount(inTopic name: String, day: String? = nil) -> Int {
        stories(inTopic: name, day: day).filter { !isRead($0) }.count
    }

    /// Unread stories first seen after `date`: the app-icon badge after a background refresh.
    func newStoryCount(since date: Date?) -> Int {
        guard let date, let brief else { return 0 }
        return brief.allStories.filter { !isRead($0) && (firstSeen[$0.id] ?? .distantPast) > date }.count
    }

    /// Stamps stories this phone hasn't seen before. The very first time (or after an upgrade)
    /// everything is stamped as long seen, so nothing shows as new on day one.
    func recordFirstSeen(in feed: SharedFeed) {
        let at = now()
        let ids = feed.stories.map(\.id)
        var updated = ReadingState.recordingFirstSeen(firstSeen, ids: ids, now: at, seenBefore: hasSeenHistory)
        updated = ReadingState.prunedFirstSeen(updated, feedIDs: Set(ids), now: at)
        hasSeenHistory = true
        guard updated != firstSeen else { return }
        firstSeen = updated
        scheduleWrite(.seen)
    }

    // MARK: Saved

    func isSaved(_ story: Story) -> Bool { saved.contains { $0.id == story.id } }

    func setSaved(_ story: Story, _ save: Bool) {
        if save {
            guard !isSaved(story) else { return }
            saved.insert(SavedStory(story: story, savedAt: now()), at: 0)
        } else {
            guard isSaved(story) else { return }
            saved.removeAll { $0.id == story.id }
        }
        scheduleWrite(.saved)
    }

    func toggleSaved(_ story: Story) { setSaved(story, !isSaved(story)) }

    func removeSaved(ids: Set<String>) {
        saved.removeAll { ids.contains($0.id) }
        scheduleWrite(.saved)
    }

    // MARK: Persistence

    /// Forgets everything kept for the signed-in reader (a different account, or account deleted).
    /// The files themselves are removed by `LocalStore.resetForNewUser`.
    func clearUserData() {
        for task in writeTasks.values { task.cancel() }
        writeTasks = [:]
        // A write still waiting its turn mustn't put the old account's state back.
        for task in writesInFlight.values { task.cancel() }
        writesInFlight = [:]
        dirtyFiles = []
        readAt = [:]
        firstSeen = [:]
        hasSeenHistory = false
        previousVisitAt = nil
        saved = []
        recent = []
        historyIndex = []
        pastBriefs = [:]
        let store = historyStore
        Task { await store.removeAll() }
    }

    func scheduleWrite(_ file: LocalStore.File) {
        dirtyFiles.insert(file)
        writeTasks[file]?.cancel()
        writeTasks[file] = Task { [weak self, delay = stateWriteDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.writeNow(file)
        }
    }

    /// Writes every changed file now (backgrounding, tests).
    func flushLocalState() async {
        for file in dirtyFiles { await writeNow(file) }
        // Including writes a debounce started before this was called.
        for task in writesInFlight.values { _ = await task.value }
    }

    private func writeNow(_ file: LocalStore.File) async {
        guard dirtyFiles.remove(file) != nil else { return }
        // Resolved now, on the main actor: the demo mode and tests point LocalStore elsewhere.
        let target = LocalStore.url(file)
        // Each write waits for the one before it: an older snapshot finishing last would undo
        // newer changes on disk.
        let previous = writesInFlight[file]
        let job: Task<Bool, Never>
        switch file {
        case .read: job = Self.write(readAt, to: target, after: previous)
        case .seen: job = Self.write(firstSeen, to: target, after: previous)
        case .saved: job = Self.write(saved, to: target, after: previous)
        case .recent: job = Self.write(recent, to: target, after: previous)
        case .feed: return
        }
        writesInFlight[file] = job
        if !(await job.value) { dirtyFiles.insert(file) }  // try again with the next write or flush
    }

    /// Encodes and writes off the main thread, once `previous` has finished.
    private nonisolated static func write<T: Encodable & Sendable>(_ value: T, to url: URL,
                                                                    after previous: Task<Bool, Never>?) -> Task<Bool, Never> {
        Task.detached(priority: .utility) {
            _ = await previous?.value
            guard !Task.isCancelled, let data = try? JSONEncoder.api.encode(value) else { return false }
            return LocalStore.write(data, to: url)
        }
    }
}
