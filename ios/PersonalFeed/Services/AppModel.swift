import AuthenticationServices
import Foundation
import Observation
import os
import SwiftUI
import UIKit
import UserNotifications

/// App state: account, settings, the shared feed and the brief built from it, reading state and
/// navigation. Reading state is in AppModel+Reading.swift, navigation and push taps in
/// AppModel+Routing.swift, scene lifecycle, push and background refresh in AppModel+Lifecycle.swift.
@MainActor
@Observable
final class AppModel {
    enum Phase { case restoring, signedOut, onboarding, ready }

    // MARK: Account and settings

    private(set) var phase: Phase = .restoring
    private(set) var settings = UserSettings.default
    /// Sign-in, delete-account and session problems. Shown in Settings and on the sign-in screen,
    /// never on Today (feed problems are `feedStatus`).
    var accountError: String?

    /// Where the topic picker's changes are on their way to the account.
    enum SaveState: Equatable {
        case idle, saving, saved
        /// Not saved yet (offline); kept on the phone and retried.
        case failed(String)
        /// The account refused the change (e.g. too many entries); the account's copy was reloaded.
        case rejected(String)
    }
    private(set) var saveState: SaveState = .idle

    // MARK: Feed and brief

    private(set) var feed: SharedFeed?
    /// What Today shows.
    private(set) var brief: Brief?
    /// Every topic, followed or not (same sources and muted words): unfollowed topic pages,
    /// "All topics" search and related stories.
    private(set) var allTopicsBrief: Brief?
    /// Why the last feed check failed; nil once one succeeds. For Today only.
    private(set) var feedStatus: FeedStatus?
    /// When the phone last heard back from the feed (200 or 304), persisted.
    private(set) var lastCheckedAt: Date?
    /// True at launch until the cached feed and brief are loaded, so Today can show placeholders
    /// instead of "No news yet".
    private(set) var isRestoringCache = false
    private var refreshTask: Task<RefreshOutcome, Never>?
    var isRefreshing: Bool { refreshTask != nil }

    /// A newer brief from an automatic refresh, held while the reader is scrolled down Today so
    /// rows don't move under their thumb. Apply with `applyPendingBrief()`.
    private(set) var pendingBrief: Brief?
    /// Stories in `pendingBrief` that Today doesn't show yet.
    private(set) var pendingNewCount = 0
    /// Set by Today: true while its header is on screen. Coming back to the top applies a pending brief.
    var todayIsAtTop = true {
        didSet { if todayIsAtTop, !oldValue, pendingBrief != nil { applyPendingBrief() } }
    }
    /// What "Hide read stories" hides on Today: the stories read before this visit (or before the
    /// last pull to refresh). Kept here, not in the view, so a story read a moment ago doesn't vanish
    /// when an update lands or a search replaces the list for a moment.
    var todayReadSnapshot: Set<String>?

    // The properties below are written by AppModel's extensions in other files, so their setters
    // can't be private; views only read them.

    // MARK: History

    /// Past briefs on this phone, newest first (today included; see `pastBriefEntries`).
    var historyIndex: [HistoryEntry] = []
    /// Past briefs opened recently, by date.
    var pastBriefs: [String: Brief] = [:]

    // MARK: Reading state (see AppModel+Reading.swift)

    /// Story id → when it was marked read.
    var readAt: [String: Date] = [:]
    /// Story id → when this phone first saw it in the feed.
    var firstSeen: [String: Date] = [:]
    /// When the reader's previous visit ended; stories first seen after it are new.
    var previousVisitAt: Date?
    /// Newest first.
    var saved: [SavedStory] = []
    /// Newest first, at most 50.
    var recent: [RecentStory] = []

    // MARK: Navigation (see AppModel+Routing.swift)

    var selectedTab: AppTab = .today
    var todayPath = NavigationPath()
    var savedPath = NavigationPath()
    /// The one article sheet. Set through `openArticle`.
    var presentedArticle: ArticleLink?
    var searchQuery = ""
    var searchScope: SearchScope = .mine
    var isSearchPresented = false
    /// Incremented when Today should scroll back to its top (a "brief ready" push).
    var scrollToTopRequest = 0
    /// A tapped notification waiting for the app to be ready.
    var pendingRoute: NotificationRoute?

    // MARK: Push

    var notificationStatus: UNAuthorizationStatus = .notDetermined

    // MARK: Dependencies (replaced in tests)

    @ObservationIgnored var sessionToken: String?
    /// Sends settings to the account.
    @ObservationIgnored var sendSettings: (UserSettings, String) async throws -> UserSettings = { settings, token in
        guard let api = APIClient.fromBundle() else { throw APIError.notConfigured }
        return try await api.save(settings: settings, token: token)
    }
    /// GET /v1/feed with an optional If-None-Match.
    @ObservationIgnored var fetchFeed: (String?) async throws -> APIClient.FeedResult = { etag in
        guard let api = APIClient.fromBundle() else { throw APIError.notConfigured }
        return try await api.feed(etag: etag)
    }
    /// GET /v1/me.
    @ObservationIgnored var fetchAccount: (String) async throws -> AccountSnapshot = { token in
        guard let api = APIClient.fromBundle() else { throw APIError.notConfigured }
        return try await api.account(token: token)
    }
    /// Asks iOS for notification permission (a system prompt, so tests replace it).
    @ObservationIgnored var requestNotificationPermission: () async -> Bool = {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    @ObservationIgnored var tokenStore = TokenStore.keychain
    @ObservationIgnored var clock: () -> Date = { Date() }
    /// How long to wait after the last change before saving, so a run of toggles is one request.
    @ObservationIgnored var saveDelay: Duration = .milliseconds(600)
    @ObservationIgnored var historySaveDelay: Duration = .seconds(2)
    @ObservationIgnored var stateWriteDelay: Duration = .seconds(1)
    @ObservationIgnored var retryDelay: Duration = .seconds(2)
    @ObservationIgnored var autoRefreshInterval: Duration = .seconds(5 * 60)
    @ObservationIgnored var historyStore: HistoryStore

    // MARK: Private state

    /// Account calls (sign in, sign out, delete, device registration); nil in tests.
    @ObservationIgnored var api = APIClient.fromBundle()
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var needsAnotherFlush = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var feedETag: String?
    @ObservationIgnored var deviceToken: String?
    @ObservationIgnored private var restoreStarted = false
    @ObservationIgnored private var restoreCoreTask: Task<Void, Never>?
    /// The account's settings couldn't be loaded at launch (a reinstall while offline); fetch
    /// them after the next successful feed check.
    @ObservationIgnored private var needsAccountSettings = false
    @ObservationIgnored private var accountSync: Task<Void, Never>?
    @ObservationIgnored private var lastBuild: BuildStamp?
    @ObservationIgnored private var feedWrite: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var unsavedBrief: Brief?
    @ObservationIgnored var hasSeenHistory = false
    @ObservationIgnored var writeTasks: [LocalStore.File: Task<Void, Never>] = [:]
    @ObservationIgnored var dirtyFiles: Set<LocalStore.File> = []
    /// Set once the first feed check after becoming ready is done; push taps wait for it.
    @ObservationIgnored var initialRefreshDone = false
    @ObservationIgnored var sceneIsActive = false
    @ObservationIgnored var visitStartedAt: Date?
    @ObservationIgnored var autoRefreshTask: Task<Void, Never>?
    @ObservationIgnored var observers: [NSObjectProtocol] = []
    @ObservationIgnored var relatedIndex: (key: String, index: RelatedStories)?
    @ObservationIgnored var isDemo = false

    static let log = Logger(subsystem: "com.lilscuba.brief", category: "app")

    private struct BuildStamp {
        let day: String
        let window: Double
        let at: Date
    }

    init() {
        historyStore = HistoryStore()
    }

    func now() -> Date { clock() }

    // MARK: Launch / sign in

    /// Called once when the UI appears. Decides the phase from instant local state first, loads the
    /// cached feed off the main thread, then checks for news and syncs settings.
    func restore() async {
        guard !restoreStarted else { return }
        restoreStarted = true
        #if DEBUG
        if DemoMode.isEnabled {
            await startDemo()
            return
        }
        #endif
        let token = tokenStore.load()
        sessionToken = token
        settings = LocalStore.settings ?? .default
        // The Keychain survives deleting the app but UserDefaults doesn't: a token with no record of
        // onboarding on this install means a reinstall, and the account already has settings.
        let reinstalled = token != nil && !LocalStore.onboarded && LocalStore.userID == nil
        if token == nil {
            phase = .signedOut
        } else if LocalStore.onboarded {
            phase = .ready
        } else if !reinstalled {
            phase = .onboarding
        }
        isRestoringCache = true
        await restoreCore()
        isRestoringCache = false
        guard let token else { return }
        var fetchedAccount = false
        if reinstalled {
            fetchedAccount = await adoptExistingAccount(token: token)
            guard phase != .signedOut else { return }
        }
        rebuild()
        if phase == .ready { beginVisitIfActive() }
        await refresh(reason: .launch)
        if !fetchedAccount { await syncAccountSettings() }
        // Permissions don't survive a reinstall: ask again, as onboarding would have.
        if fetchedAccount, phase == .ready { await askForPushIfWanted() }
        if phase == .ready, !initialRefreshDone { await didBecomeReady() }
    }

    /// Loads everything a refresh needs without touching the UI: token, settings, cached feed and
    /// ETag, reading state and the history index. Shared by launch and background refresh, and
    /// safe to call more than once.
    func restoreCore() async {
        if let restoreCoreTask { await restoreCoreTask.value; return }
        let task = Task { await loadLocalState() }
        restoreCoreTask = task
        await task.value
    }

    private struct LocalSnapshot: Sendable {
        let feed: SharedFeed?
        let reads: [String: Date]?
        let seen: [String: Date]?
        let saved: [SavedStory]?
        let recent: [RecentStory]?
    }

    private func loadLocalState() async {
        if sessionToken == nil { sessionToken = tokenStore.load() }
        if let stored = LocalStore.settings { settings = stored }
        deviceToken = LocalStore.deviceToken
        lastCheckedAt = LocalStore.feedCheckedAt
        previousVisitAt = LocalStore.lastVisitAt
        let legacyReads = LocalStore.legacyReadIDs
        let loaded = await Task.detached(priority: .userInitiated) {
            LocalSnapshot(feed: LocalStore.loadFeed(),
                          reads: LocalStore.load([String: Date].self, .read),
                          seen: LocalStore.load([String: Date].self, .seen),
                          saved: LocalStore.load([SavedStory].self, .saved),
                          recent: LocalStore.load([RecentStory].self, .recent))
        }.value
        let index = await historyStore.loadIndex(now: now())

        if let cached = loaded.feed, cached.generatedAt > (feed?.generatedAt ?? .distantPast) {
            feed = cached
            feedETag = LocalStore.feedETag ?? APIClient.etag(for: cached.generatedAt)
        }
        if let reads = loaded.reads {
            readAt = ReadingState.prunedReads(reads, now: now())
            if readAt.count != reads.count { scheduleWrite(.read) }
        } else if let legacy = legacyReads, !legacy.isEmpty {
            let at = now()
            readAt = Dictionary(legacy.map { ($0, at) }, uniquingKeysWith: { first, _ in first })
            scheduleWrite(.read)
        }
        hasSeenHistory = loaded.seen != nil
        firstSeen = loaded.seen ?? [:]
        saved = loaded.saved ?? []
        recent = loaded.recent ?? []
        historyIndex = index
        if let feed { recordFirstSeen(in: feed) }
        startObservingSystemChanges()
    }

    /// After a reinstall: load the account's settings instead of onboarding again, which would
    /// overwrite them with defaults. Returns true when they were loaded.
    private func adoptExistingAccount(token: String) async -> Bool {
        do {
            let account = try await fetchAccount(token)
            if let id = account.userID { LocalStore.userID = id }
            applyServerSettings(account.settings)
            LocalStore.onboarded = true
            phase = .ready
            return true
        } catch APIError.unauthorized {
            endSession(.expired)
        } catch {
            // Offline: onboarding follows the account's settings once they arrive.
            needsAccountSettings = true
            phase = .onboarding
        }
        return false
    }

    /// Onboarding after a reinstall that couldn't reach the account: try again, and once it loads
    /// skip onboarding, as a launch with a connection would have. True when the account loaded.
    @discardableResult
    func retryReinstalledAccount() async -> Bool {
        guard phase == .onboarding, needsAccountSettings, let token = sessionToken,
              await adoptExistingAccount(token: token) else { return false }
        needsAccountSettings = false
        rebuild()
        beginVisitIfActive()
        await refresh(reason: .launch)
        await askForPushIfWanted()
        await didBecomeReady()
        return true
    }

    /// Sends settings changed while offline, or else adopts the account's copy. Overlapping calls
    /// (launch, and the first feed check after a reinstall while offline) share one request.
    private func syncAccountSettings() async {
        if let accountSync { return await accountSync.value }
        let task = Task { await performAccountSync() }
        accountSync = task
        await task.value
        accountSync = nil
    }

    private func performAccountSync() async {
        guard let token = sessionToken else { return }
        // A reinstall still in onboarding: once the account answers, adopt it and skip onboarding,
        // so "Create my feed" can never send a draft of defaults over it.
        if phase == .onboarding, needsAccountSettings {
            await retryReinstalledAccount()
            return
        }
        if LocalStore.settingsPending {
            // Choices made on this phone that never reached the account (offline, app closed
            // too soon): send them rather than overwrite them with the older server copy.
            await flushSettings()
            return
        }
        do {
            let before = settings
            let account = try await fetchAccount(token)
            needsAccountSettings = false
            // A change made while this was loading wins, even one already saved by now.
            if settings == before, !LocalStore.settingsPending { applyServerSettings(account.settings) }
        } catch APIError.unauthorized {
            endSession(.expired)
        } catch {
            // Offline is fine: keep the cached settings.
        }
    }

    /// Everything that waits for the first check after reaching `.ready`.
    func didBecomeReady() async {
        initialRefreshDone = true
        beginVisitIfActive()
        startAutoRefreshIfActive()
        await processPendingRoute()
        await registerForPushIfAuthorized()
        syncTimeZone()
    }

    func signIn(with result: Result<ASAuthorization, Error>) async {
        accountError = nil
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                accountError = error.localizedDescription
            }
        case .success(let auth):
            guard let api else { accountError = APIError.notConfigured.localizedDescription; return }
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let identityToken = String(data: data, encoding: .utf8)
            else { accountError = "Apple didn't return a sign-in token. Please try again."; return }
            do {
                let response = try await api.signInWithApple(identityToken: identityToken)
                if LocalStore.userID != response.user.id {
                    LocalStore.resetForNewUser(response.user.id)
                    clearUserData()
                }
                tokenStore.save(response.token)
                sessionToken = response.token
                applyServerSettings(response.settings)
                phase = (response.created || !LocalStore.onboarded) ? .onboarding : .ready
                if phase == .ready { await askForPushIfWanted() }
                await refresh(reason: .launch)
                if phase == .ready { await didBecomeReady() }
            } catch {
                accountError = error.localizedDescription
            }
        }
    }

    /// Called when the user taps "Create my feed" at the end of onboarding.
    func finishOnboarding(with newSettings: UserSettings) async {
        // A reinstall whose account couldn't be reached: the account already has settings, and
        // saving this draft would replace its muted words, boosts and sources with defaults.
        if needsAccountSettings {
            accountError = nil
            if await retryReinstalledAccount() { return }
            if phase == .onboarding {
                accountError = "Couldn't reach your account to load your settings. Check your connection and try again."
            }
            return
        }
        update(newSettings)
        await flushSettings()
        // A 401 while saving ends the session: then this is the sign-in screen, not Today.
        guard phase == .onboarding, sessionToken != nil else { return }
        LocalStore.onboarded = true
        phase = .ready
        await askForPushIfWanted()
        await refresh(reason: .launch)
        await didBecomeReady()
    }

    func signOut() async {
        if let api, let token = sessionToken {
            if let deviceToken { try? await api.removeDevice(deviceToken, token: token) }
            try? await api.logout(token: token)
        }
        endSession(.signedOut)
    }

    func deleteAccount() async {
        guard let api, let token = sessionToken else { return }
        accountError = nil
        do {
            try await api.deleteAccount(token: token)
            LocalStore.resetForNewUser(nil)
            clearUserData()
            endSession(.signedOut)
        } catch {
            accountError = "Couldn't delete your account: \(error.localizedDescription)"
        }
    }

    #if DEBUG
    /// Demo mode (DemoMode.swift): signed out of any account but showing the brief.
    func enterDemo(settings demo: UserSettings) {
        sessionToken = nil
        settings = demo
        phase = .ready
    }
    #endif

    enum SessionEnd { case signedOut, expired }

    private func endSession(_ reason: SessionEnd) {
        tokenStore.delete()
        sessionToken = nil
        settings = .default
        LocalStore.settings = nil
        LocalStore.settingsPending = false
        saveState = .idle
        LocalStore.onboarded = false
        feedStatus = nil
        accountError = reason == .expired ? APIError.unauthorized.localizedDescription : nil
        pendingRoute = nil
        presentedArticle = nil
        clearSearch()
        todayReadSnapshot = nil
        todayPath = NavigationPath()
        savedPath = NavigationPath()
        selectedTab = .today
        initialRefreshDone = false
        needsAccountSettings = false
        // The next account must not see this one's brief (its topics, mutes and sources) or badge.
        brief = nil
        allTopicsBrief = nil
        pendingBrief = nil
        pendingNewCount = 0
        lastBuild = nil
        clearBadge()
        stopAutoRefresh()
        phase = .signedOut
    }

    // MARK: Settings

    /// Apply a change immediately on the phone, then save it to the account shortly after
    /// (debounced, so dragging a stepper doesn't send ten requests). Nothing is lost if the
    /// save is slow or fails: the change stays marked pending and is sent again later.
    func update(_ newSettings: UserSettings) {
        guard newSettings != settings else { return }
        let affectsBrief = newSettings.briefKey != settings.briefKey
        settings = newSettings
        LocalStore.settings = newSettings
        // Alert and morning-brief edits don't change the brief.
        if affectsBrief { rebuild() }
        guard sessionToken != nil, !isDemo else { return }
        LocalStore.settingsPending = true
        saveState = .saving
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: self?.saveDelay ?? .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            // Unstructured on purpose: a later edit cancels this debounce task, and that must not
            // cancel the request already on its way.
            Task { await self.flushSettings() }
        }
    }

    /// Sends the current settings to the account, and keeps going while newer changes arrive.
    /// The server's reply is only adopted if nothing changed meanwhile; applying an older reply
    /// over newer choices is what used to flip a just-tapped topic back off.
    func flushSettings() async {
        saveTask?.cancel()
        guard sessionToken != nil else { return }
        if flushing { needsAnotherFlush = true; return }
        flushing = true
        defer { flushing = false }
        repeat {
            needsAnotherFlush = false
            guard let token = sessionToken else { return }
            let sent = settings
            saveState = .saving
            do {
                let saved = try await sendSettings(sent, token)
                if settings == sent {
                    applyServerSettings(saved)
                    LocalStore.settingsPending = false
                    saveState = .saved
                } else {
                    needsAnotherFlush = true
                }
            } catch APIError.unauthorized {
                endSession(.expired)
                return
            } catch APIError.server(let code, let message) where Self.isRejection(code) {
                // The account refused these settings (e.g. over a list limit). Retrying won't
                // help, so stop retrying and show the account's copy so phone and account agree.
                if settings != sent { needsAnotherFlush = true; continue }
                LocalStore.settingsPending = false
                saveState = .rejected(message)
                let account = try? await fetchAccount(token)
                // An edit made while that loaded (the reader fixing the problem) still has to go out.
                if needsAnotherFlush || settings != sent { needsAnotherFlush = true; continue }
                if let account, !LocalStore.settingsPending { applyServerSettings(account.settings) }
                return
            } catch {
                saveState = .failed(error.localizedDescription)  // stays pending; retried later
                return
            }
        } while needsAnotherFlush
    }

    /// 4xx answers that mean "invalid", not "try again later".
    static func isRejection(_ code: Int) -> Bool {
        (400..<500).contains(code) && ![401, 408, 429].contains(code)
    }

    var hasPendingSettings: Bool { LocalStore.settingsPending }

    /// Called when the app moves to the background (with a background-task grace period so the
    /// request can finish) and when it comes back (to retry a failed save).
    func flushPendingSettings() {
        guard hasPendingSettings, sessionToken != nil else { return }
        withBackgroundTime("Save settings") { await self.flushSettings() }
    }

    private func applyServerSettings(_ s: UserSettings) {
        let affectsBrief = s.briefKey != settings.briefKey
        settings = s
        LocalStore.settings = s
        if affectsBrief { rebuild() }
    }

    // MARK: Feed

    /// Stops the check in progress (its request too); background refresh calls this when iOS's
    /// time is up.
    func cancelRefresh() {
        refreshTask?.cancel()
    }

    /// Checks for a newer feed. Overlapping calls share one request. Automatic checks (foreground,
    /// timer, background) are skipped when the last one answered under a minute ago, the
    /// server's cache lifetime; pull-to-refresh, launch and push-triggered checks always go out.
    @discardableResult
    func refresh(reason: RefreshReason = .user) async -> RefreshOutcome {
        if let running = refreshTask {
            let outcome = await running.value
            if reason.appliesImmediately { applyPendingBrief() }
            return outcome
        }
        if reason.isThrottled, let last = lastCheckedAt, now().timeIntervalSince(last) < 60 {
            return .unchanged
        }
        let task = Task { await performRefresh(reason) }
        refreshTask = task
        let outcome = await task.value
        refreshTask = nil
        return outcome
    }

    private func performRefresh(_ reason: RefreshReason) async -> RefreshOutcome {
        let result: APIClient.FeedResult
        do {
            // No ETag without a cached feed: a 304 would leave nothing to show.
            // iOS gives a background refresh about 30 s: no time for a retry after a 20 s timeout.
            result = try await fetchFeedRetrying(etag: feed == nil ? nil : APIClient.ifNoneMatch(feedETag),
                                                 retry: reason != .background)
        } catch {
            feedStatus = FeedStatus(error)
            Self.log.error("Feed check failed: \(String(describing: error), privacy: .public)")
            return .failed
        }
        feedStatus = nil
        let checked = now()
        lastCheckedAt = checked
        LocalStore.feedCheckedAt = checked
        if needsAccountSettings { Task { await syncAccountSettings() } }

        switch result {
        case .notModified:
            // Still rebuild now and then, so the 24 h window slides and the date rolls over.
            if brief == nil || buildIsStale { rebuild(reason.applyPolicy) }
            return .unchanged
        case .fresh(let newFeed, let data, let etag):
            // Never step back to an older feed (a slow reply overtaken by a newer one).
            if let current = feed, newFeed.generatedAt < current.generatedAt { return .unchanged }
            let isNewer = feed.map { newFeed.generatedAt > $0.generatedAt } ?? true
            let tag = etag ?? APIClient.etag(for: newFeed.generatedAt)
            feed = newFeed
            feedETag = tag
            if isNewer || LocalStore.feedETag == nil { persistFeed(data, etag: tag) }
            recordFirstSeen(in: newFeed)
            guard isNewer || brief == nil || buildIsStale else { return .unchanged }
            let before = Set((pendingBrief ?? brief)?.allStories.map(\.id) ?? [])
            rebuild(reason.applyPolicy)
            let after = Set((pendingBrief ?? brief)?.allStories.map(\.id) ?? [])
            return .updated(newCount: after.subtracting(before).count)
        }
    }

    /// One retry, after a short pause, for a server error or a timeout.
    private func fetchFeedRetrying(etag: String?, retry: Bool) async throws -> APIClient.FeedResult {
        do {
            return try await fetchFeed(etag)
        } catch let error where retry && Self.isRetryable(error) {
            try? await Task.sleep(for: retryDelay)
            return try await fetchFeed(etag)
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        if case .server(let code, _)? = error as? APIError { return (500..<600).contains(code) }
        return (error as? URLError)?.code == .timedOut
    }

    /// Writes feed.json, then its ETag (so the ETag never describes a file that wasn't saved).
    /// Writes are chained so an older one can't land after a newer one.
    private func persistFeed(_ data: Data, etag: String) {
        let previous = feedWrite
        // Resolved now, on the main actor: the demo mode and tests point LocalStore elsewhere.
        let target = LocalStore.url(.feed)
        let defaults = LocalStore.defaults
        feedWrite = Task.detached(priority: .utility) {
            await previous?.value
            if LocalStore.write(data, to: target) { defaults.set(etag, forKey: LocalStore.feedETagKey) }
        }
    }

    /// Waits for pending feed.json writes (tests, background refresh).
    func flushFeedWrite() async { await feedWrite?.value }

    enum ApplyPolicy { case now, deferWhileReading }

    /// Rebuilds the brief from the feed and settings. With `.deferWhileReading`, a changed brief is
    /// held in `pendingBrief` while the reader is scrolled down Today (never across a date change).
    func rebuild(_ policy: ApplyPolicy = .now) {
        guard let feed, phase != .signedOut else { return }
        let at = now()
        let window = BriefBuilder.catchUpHours(lastVisit: previousVisitAt, feed: feed, now: at)
        let built = BriefBuilder.build(feed: feed, settings: settings, now: at, windowHours: window)
        allTopicsBrief = BriefBuilder.allTopics(feed: feed, settings: settings, now: at, windowHours: window)
        lastBuild = BuildStamp(day: built.date, window: window, at: at)
        if policy == .deferWhileReading, let shown = brief, shown.date == built.date,
           selectedTab == .today, !todayIsAtTop {
            if HistoryStore.signature(of: built) == HistoryStore.signature(of: shown) {
                pendingBrief = nil
                pendingNewCount = 0
            } else {
                pendingBrief = built
                pendingNewCount = Set(built.allStories.map(\.id)).subtracting(shown.allStories.map(\.id)).count
            }
        } else {
            brief = built
            pendingBrief = nil
            pendingNewCount = 0
        }
        scheduleHistorySave(built)
    }

    /// Shows the held brief (the "↑ N new stories" button).
    func applyPendingBrief() {
        guard let pendingBrief else { return }
        brief = pendingBrief
        self.pendingBrief = nil
        pendingNewCount = 0
    }

    /// The brief is due for a rebuild without new data: 10 minutes old, a new day, or the
    /// catch-up window changed.
    private var buildIsStale: Bool {
        guard let lastBuild, let feed else { return true }
        let at = now()
        return at.timeIntervalSince(lastBuild.at) >= 600
            || Brief.day(of: at) != lastBuild.day
            || BriefBuilder.catchUpHours(lastVisit: previousVisitAt, feed: feed, now: at) != lastBuild.window
    }

    /// Midnight or a time-zone change: the date and the window moved.
    func handleSignificantTimeChange() {
        rebuild()
    }

    // MARK: History

    private func scheduleHistorySave(_ snapshot: Brief) {
        unsavedBrief = snapshot
        historyTask?.cancel()
        let at = now()
        historyTask = Task { [weak self, historyStore, delay = historySaveDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let index = await historyStore.save(snapshot, now: at)
            // Once written, the index is real even if a newer save was scheduled meanwhile.
            guard let self else { return }
            if self.unsavedBrief == snapshot { self.unsavedBrief = nil }
            if let index { self.historyIndex = index }
        }
    }

    /// Saves the latest brief now instead of after the debounce (backgrounding, tests).
    func flushHistory() async {
        historyTask?.cancel()
        historyTask = nil
        if let snapshot = unsavedBrief {
            unsavedBrief = nil
            _ = await historyStore.save(snapshot, now: now())
        }
        historyIndex = await historyStore.loadIndex(now: now())
    }

    /// Past briefs, newest first, without today's (Today already shows it).
    var pastBriefEntries: [HistoryEntry] {
        let today = brief?.date ?? Brief.day(of: now())
        return historyIndex.filter { $0.date != today }
    }

    /// A day's brief: today's live one, or a past one loaded from disk (kept for reuse).
    func loadBrief(day: String) async -> Brief? {
        if day == brief?.date { return brief }
        if let cached = pastBriefs[day] { return cached }
        guard let loaded = await historyStore.loadBrief(date: day) else { return nil }
        if pastBriefs.count >= 5 { pastBriefs.removeAll() }
        pastBriefs[day] = loaded
        return loaded
    }

    /// `day` nil is today's live brief; otherwise a past brief already loaded with `loadBrief(day:)`.
    func brief(for day: String?) -> Brief? {
        guard let day, day != brief?.date else { return brief }
        return pastBriefs[day]
    }

    // MARK: Topics

    func isFollowing(_ topic: String) -> Bool { settings.categories.contains(topic) }

    /// Every story of a topic, including the ones in Top stories, in hot order. Today's unfollowed
    /// topics come from the all-topics brief so they can be browsed before following them.
    func stories(inTopic name: String, day: String? = nil) -> [Story] {
        if let day, day != brief?.date { return pastBriefs[day]?.stories(inTopic: name) ?? [] }
        if isFollowing(name) { return brief?.stories(inTopic: name) ?? [] }
        return allTopicsBrief?.stories(inTopic: name) ?? []
    }

    /// Follow or unfollow a topic (appended at the end of the reader's order).
    func setFollowing(_ topic: String, _ follow: Bool) {
        var s = settings
        s.setCategory(topic, enabled: follow)
        update(s)
    }

    // MARK: Search and related

    /// Stories matching `query`, headline matches first, then hot order across topics.
    func search(_ query: String, scope: SearchScope) -> [Story] {
        // A held update is news too: "My topics" mustn't lag behind "All topics", which is always current.
        let pool = scope == .mine ? (pendingBrief ?? brief) : allTopicsBrief
        return StorySearch.filter(pool?.allStoriesByScore ?? [], query: query)
    }

    /// Other stories about the same event, from any topic.
    func relatedStories(to story: Story, limit: Int = 4) -> [Story] {
        guard let corpus = allTopicsBrief else { return [] }
        let key = HistoryStore.signature(of: corpus)
        let index: RelatedStories
        if let cached = relatedIndex, cached.key == key {
            index = cached.index
        } else {
            index = RelatedStories(stories: corpus.allStories)
            relatedIndex = (key, index)
        }
        return index.related(to: story, limit: limit)
    }
}

// MARK: - Supporting types

enum RefreshReason: Sendable {
    case launch, user, foreground, auto, push, background

    /// Skipped when the feed was checked under a minute ago.
    var isThrottled: Bool { self == .foreground || self == .auto || self == .background }

    /// Apply a new brief right away. Automatic checks while the reader is scrolled down Today are
    /// held as a pending brief instead.
    var appliesImmediately: Bool { self != .auto && self != .push }

    var applyPolicy: AppModel.ApplyPolicy { appliesImmediately ? .now : .deferWhileReading }
}

enum RefreshOutcome: Hashable, Sendable {
    /// A newer feed arrived; `newCount` stories weren't in the brief before.
    case updated(newCount: Int)
    case unchanged
    case failed
}

/// Why the feed couldn't be checked. Shown on Today only.
enum FeedStatus: Equatable, Sendable {
    case offline
    case server(Int)
    /// The feed changed shape and this version can't read it: needs an app update.
    case unreadable
    case notConfigured

    init(_ error: Error) {
        if let api = error as? APIError {
            switch api {
            case .server(let code, _): self = .server(code)
            case .unauthorized: self = .server(401)
            case .notConfigured: self = .notConfigured
            }
        } else if error is DecodingError {
            self = .unreadable
        } else {
            self = .offline  // URLError: no connection, timed out, host unreachable
        }
    }

    var message: String {
        switch self {
        case .offline: "You're offline"
        case .server(let code): "Brief's server had a problem (\(code))"
        case .unreadable: "This version of Brief can't read the latest news. Please update the app."
        case .notConfigured: APIError.notConfigured.localizedDescription
        }
    }

    var systemImage: String {
        switch self {
        case .offline: "wifi.slash"
        case .server: "exclamationmark.icloud"
        case .unreadable: "arrow.down.app"
        case .notConfigured: "gearshape"
        }
    }
}

/// Where the session token is kept; in memory for tests.
struct TokenStore: Sendable {
    var load: @Sendable () -> String?
    var save: @Sendable (String) -> Void
    var delete: @Sendable () -> Void

    static let keychain = TokenStore(load: { Keychain.load() }, save: { Keychain.save($0) },
                                     delete: { Keychain.delete() })
}
