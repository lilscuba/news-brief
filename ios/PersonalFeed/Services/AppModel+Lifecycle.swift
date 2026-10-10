import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// Scene lifecycle, keeping the feed fresh while the app is open or in the background, push
/// registration and the app-icon badge.
extension AppModel {
    static let backgroundRefreshID = "com.lilscuba.brief.refresh"
    /// @AppStorage key for "Show new-story count on app icon" (default on).
    static let showBadgeKey = "showBadge"
    /// A visit shorter than this (a glance from a notification) doesn't reset what counts as new.
    static let minimumVisit: TimeInterval = 10

    // MARK: Scene phase

    func sceneDidBecomeActive() {
        sceneIsActive = true
        if phase == .onboarding { Task { await retryReinstalledAccount() } }
        guard phase == .ready else { return }
        beginVisitIfActive()
        startAutoRefreshIfActive()
        syncTimeZone()
        if selectedTab == .today { clearBadge() }
        Task {
            await registerIfNewlyAllowed()
            await refresh(reason: .foreground)
        }
        flushPendingSettings()  // retry anything that didn't save
    }

    func sceneWillResignActive() {
        sceneIsActive = false
        stopAutoRefresh()
    }

    func sceneDidEnterBackground() {
        sceneIsActive = false
        stopAutoRefresh()
        if let start = visitStartedAt, now().timeIntervalSince(start) >= Self.minimumVisit {
            LocalStore.lastVisitAt = now()
        }
        visitStartedAt = nil
        guard phase == .ready || phase == .onboarding else { return }
        flushPendingSettings()  // don't lose a change made just before leaving
        withBackgroundTime("Save reading state") {
            await self.flushLocalState()
            await self.flushHistory()
        }
        scheduleBackgroundRefresh()
    }

    /// A visit starts the first time the scene is active and ready after being in the background.
    /// Stories first seen after the previous visit ended count as new for the whole visit.
    func beginVisitIfActive() {
        guard sceneIsActive, phase == .ready, visitStartedAt == nil else { return }
        visitStartedAt = now()
        todayReadSnapshot = Set(readAt.keys)  // a new visit hides what was read before it
        let previous = LocalStore.lastVisitAt
        if previous != previousVisitAt {
            previousVisitAt = previous
            // The catch-up window depends on the previous visit.
            if feed != nil { rebuild() }
        }
    }

    // MARK: Auto refresh while open

    func startAutoRefreshIfActive() {
        guard sceneIsActive, phase == .ready, autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.autoRefreshInterval ?? .seconds(300))
                guard !Task.isCancelled, let self else { return }
                await self.refresh(reason: .auto)
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    func startObservingSystemChanges() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.significantTimeChangeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSignificantTimeChange() }
        })
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.syncTimeZone()
                self?.handleSignificantTimeChange()
            }
        })
    }

    // MARK: Background refresh

    /// Runs from the BGAppRefreshTask (no UI): restore what's on disk, check for news, record
    /// what's new and update the badge. Never counts as a visit.
    func backgroundRefresh() async {
        scheduleBackgroundRefresh()
        await restoreCore()
        guard sessionToken != nil || isDemo, LocalStore.onboarded || phase == .ready else { return }
        if brief == nil { rebuild() }
        // The refresh runs in its own task, so iOS's expiration (cancelling this one) has to be
        // passed on, or the request would run past the time iOS gave.
        await withTaskCancellationHandler {
            _ = await refresh(reason: .background)
        } onCancel: {
            Task { @MainActor in self.cancelRefresh() }
        }
        await flushFeedWrite()
        await flushLocalState()
        guard !Task.isCancelled else { return }
        await flushHistory()
        await updateBadge()
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshID)
        request.earliestBeginDate = now().addingTimeInterval(20 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Badge

    static var showsBadge: Bool {
        UserDefaults.standard.object(forKey: showBadgeKey) as? Bool ?? true
    }

    /// New unread stories since the last real visit, capped at 99.
    func updateBadge() async {
        guard Self.showsBadge else { return clearBadge() }
        let count = min(newStoryCount(since: LocalStore.lastVisitAt), 99)
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    /// Called when Today is shown, or the badge setting is turned off.
    func clearBadge() {
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(0) }
    }

    // MARK: Push

    func refreshNotificationStatus() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// The Settings "Allow notifications" button. When the reader once said no, iOS won't ask
    /// again, so this opens the app's page in iOS Settings instead.
    func enablePush() async {
        await refreshNotificationStatus()
        if notificationStatus == .denied {
            openSystemNotificationSettings()
            return
        }
        await askForPush()
    }

    /// After sign-in, onboarding or a reinstall: ask for permission when the reader wants any
    /// notification. iOS only shows the prompt while undecided; a "no" is respected silently.
    func askForPushIfWanted() async {
        let wantsAny = settings.brief.notify || settings.alerts.official ||
            settings.alerts.trusted || settings.alerts.corroborated
        guard wantsAny else { return }
        await askForPush()
    }

    private func askForPush() async {
        if await requestNotificationPermission() { UIApplication.shared.registerForRemoteNotifications() }
        await refreshNotificationStatus()
    }

    func openSystemNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Notifications turned on in iOS Settings (after "Turn On in iOS Settings") don't relaunch the
    /// app, so coming back is the moment to register; otherwise the server never hears of this phone.
    func registerIfNewlyAllowed() async {
        let before = notificationStatus
        await refreshNotificationStatus()
        let allowed: Set<UNAuthorizationStatus> = [.authorized, .provisional, .ephemeral]
        if allowed.contains(notificationStatus), !allowed.contains(before) {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Re-sends the device token on every launch when allowed, as Apple recommends: tokens change,
    /// and the server drops ones APNs rejected.
    func registerForPushIfAuthorized() async {
        await refreshNotificationStatus()
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    func didRegister(deviceToken data: Data) async {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        LocalStore.deviceToken = hex
        guard let api, let token = sessionToken else { return }
        #if DEBUG
        let sandbox = true   // Xcode builds talk to APNs' sandbox
        #else
        let sandbox = false  // TestFlight and App Store builds use production
        #endif
        try? await api.registerDevice(hex, sandbox: sandbox, token: token)
    }

    /// The morning brief and the daily alert cap follow the account's time zone; keep it in step
    /// with the phone's after travel.
    func syncTimeZone() {
        NSTimeZone.resetSystemTimeZone()
        let zone = TimeZone.current.identifier
        guard phase == .ready, sessionToken != nil, settings.brief.timezone != zone else { return }
        var s = settings
        s.brief.timezone = zone
        update(s)
    }

    // MARK: Helpers

    /// Runs `work` with a background-task grace period so it can finish after the app leaves the screen.
    func withBackgroundTime(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let holder = BackgroundTaskHolder()
        holder.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { holder.end() }  // called on the main thread
        }
        Task {
            await work()
            holder.end()
        }
    }
}

@MainActor
private final class BackgroundTaskHolder {
    var id = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
