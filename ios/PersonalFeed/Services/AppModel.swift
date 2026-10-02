import AuthenticationServices
import Foundation
import Observation
import UIKit
import UserNotifications

/// App state: account, settings, the shared feed and the brief built from it.
@MainActor
@Observable
final class AppModel {
    enum Phase { case restoring, signedOut, onboarding, ready }

    private(set) var phase: Phase = .restoring
    private(set) var settings = UserSettings.default
    private(set) var feed: SharedFeed?
    private(set) var brief: Brief?
    private(set) var history: [Brief] = []
    private(set) var isLoading = false
    private(set) var readIDs: Set<String> = []
    var errorMessage: String?
    /// Set when a push notification is tapped; RootView opens it.
    var pendingURL: URL?

    private let api = APIClient.fromBundle()
    private var sessionToken: String?
    private var feedETag: String?
    private var deviceToken: String?
    private var saveTask: Task<Void, Never>?

    // MARK: Launch / sign in

    func restore() async {
        history = LocalStore.loadHistory()
        readIDs = LocalStore.readIDs
        if let cached = LocalStore.loadFeed() {
            feed = cached
        }
        guard let token = Keychain.load() else {
            phase = .signedOut
            return
        }
        sessionToken = token
        settings = LocalStore.settings ?? .default
        phase = LocalStore.onboarded ? .ready : .onboarding
        rebuild()
        await refresh()
        do {
            if let api { applyServerSettings(try await api.settings(token: token)) }
        } catch APIError.unauthorized {
            endSession()
        } catch {
            // Offline is fine: keep the cached settings.
        }
    }

    func signIn(with result: Result<ASAuthorization, Error>) async {
        errorMessage = nil
        switch result {
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                errorMessage = error.localizedDescription
            }
        case .success(let auth):
            guard let api else { errorMessage = APIError.notConfigured.localizedDescription; return }
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken, let identityToken = String(data: data, encoding: .utf8)
            else { errorMessage = "Apple didn't return a sign-in token. Please try again."; return }
            do {
                let response = try await api.signInWithApple(identityToken: identityToken)
                if LocalStore.userID != response.user.id {
                    LocalStore.resetForNewUser(response.user.id)
                    history = []
                    readIDs = []
                }
                Keychain.save(response.token)
                sessionToken = response.token
                applyServerSettings(response.settings)
                phase = (response.created || !LocalStore.onboarded) ? .onboarding : .ready
                if phase == .ready { await enablePush() }
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Called when the user taps "Create my feed" at the end of onboarding.
    func finishOnboarding(with newSettings: UserSettings) async {
        update(newSettings)
        await flushSettings()
        LocalStore.onboarded = true
        phase = .ready
        await enablePush()
        await refresh()
    }

    func signOut() async {
        if let api, let token = sessionToken {
            if let deviceToken { try? await api.removeDevice(deviceToken, token: token) }
            try? await api.logout(token: token)
        }
        endSession()
    }

    func deleteAccount() async {
        guard let api, let token = sessionToken else { return }
        do {
            try await api.deleteAccount(token: token)
            LocalStore.resetForNewUser(nil)
            history = []
            readIDs = []
            endSession()
        } catch {
            errorMessage = "Couldn't delete your account: \(error.localizedDescription)"
        }
    }

    private func endSession() {
        Keychain.delete()
        sessionToken = nil
        settings = .default
        LocalStore.settings = nil
        LocalStore.onboarded = false
        phase = .signedOut
    }

    // MARK: Settings

    /// Apply a change immediately on the phone, then save it to the account shortly after
    /// (debounced, so dragging a stepper doesn't send ten requests).
    func update(_ newSettings: UserSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        LocalStore.settings = newSettings
        rebuild()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.flushSettings()
        }
    }

    private func flushSettings() async {
        saveTask?.cancel()
        guard let api, let token = sessionToken else { return }
        do {
            applyServerSettings(try await api.save(settings: settings, token: token))
        } catch APIError.unauthorized {
            endSession()
        } catch {
            errorMessage = "Couldn't save settings: \(error.localizedDescription)"
        }
    }

    private func applyServerSettings(_ s: UserSettings) {
        settings = s
        LocalStore.settings = s
        rebuild()
    }

    // MARK: Feed

    func refresh() async {
        guard let api else { errorMessage = APIError.notConfigured.localizedDescription; return }
        isLoading = true
        defer { isLoading = false }
        do {
            switch try await api.feed(etag: feed == nil ? nil : feedETag) {
            case .notModified:
                break
            case .fresh(let newFeed, let data, let etag):
                feed = newFeed
                feedETag = etag
                LocalStore.saveFeed(data)
            }
            errorMessage = nil
            rebuild()
        } catch {
            errorMessage = feed == nil ? error.localizedDescription : "Offline: showing the last update."
        }
    }

    private func rebuild() {
        guard let feed, phase != .signedOut else { return }
        let built = BriefBuilder.build(feed: feed, settings: settings)
        brief = built
        history.removeAll { $0.date == built.date }
        history.insert(built, at: 0)
        history = Array(history.sorted { $0.date > $1.date }.prefix(LocalStore.historyDays))
        LocalStore.saveHistory(history)
    }

    func isRead(_ story: Story) -> Bool { readIDs.contains(story.id) }

    func markRead(_ story: Story) {
        guard readIDs.insert(story.id).inserted else { return }
        if readIDs.count > 3_000 { readIDs = Set(readIDs.shuffled().prefix(2_000)) }
        LocalStore.readIDs = readIDs
    }

    // MARK: Push

    func enablePush() async {
        let wantsAny = settings.brief.notify || settings.alerts.official ||
            settings.alerts.trusted || settings.alerts.corroborated
        guard wantsAny else { return }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    func didRegister(deviceToken data: Data) async {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        guard let api, let token = sessionToken else { return }
        #if DEBUG
        let sandbox = true   // Xcode builds talk to APNs' sandbox
        #else
        let sandbox = false  // TestFlight and App Store builds use production
        #endif
        try? await api.registerDevice(hex, sandbox: sandbox, token: token)
    }
}

/// Small on-device persistence: cached feed, settings copy, history and read state.
enum LocalStore {
    static let historyDays = 30
    private static let defaults = UserDefaults.standard
    private static var dir: URL { URL.applicationSupportDirectory }

    static var onboarded: Bool {
        get { defaults.bool(forKey: "onboarded") }
        set { defaults.set(newValue, forKey: "onboarded") }
    }

    static var userID: String? {
        get { defaults.string(forKey: "userID") }
        set { defaults.set(newValue, forKey: "userID") }
    }

    static var settings: UserSettings? {
        get { defaults.data(forKey: "settings").flatMap { try? JSONDecoder.api.decode(UserSettings.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder.api.encode($0) }, forKey: "settings") }
    }

    static var readIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "readIDs") ?? []) }
        set { defaults.set(Array(newValue), forKey: "readIDs") }
    }

    static func resetForNewUser(_ id: String?) {
        userID = id
        onboarded = false
        readIDs = []
        try? FileManager.default.removeItem(at: dir.appending(path: "history.json"))
    }

    static func saveFeed(_ data: Data) { write(data, "feed.json") }

    static func loadFeed() -> SharedFeed? {
        read("feed.json").flatMap { try? JSONDecoder.api.decode(SharedFeed.self, from: $0) }
    }

    static func saveHistory(_ briefs: [Brief]) {
        if let data = try? JSONEncoder.api.encode(briefs) { write(data, "history.json") }
    }

    static func loadHistory() -> [Brief] {
        read("history.json").flatMap { try? JSONDecoder.api.decode([Brief].self, from: $0) } ?? []
    }

    private static func write(_ data: Data, _ name: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appending(path: name), options: .atomic)
    }

    private static func read(_ name: String) -> Data? {
        try? Data(contentsOf: dir.appending(path: name))
    }
}
