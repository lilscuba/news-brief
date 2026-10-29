import SwiftUI
import UIKit
import UserNotifications

@main
struct PersonalFeedApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .task { await delegate.model.restore() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, delegate.model.phase == .ready {
                Task { await delegate.model.refresh() }
                delegate.model.flushPendingSettings()   // retry anything that didn't save
            } else if phase == .background {
                delegate.model.flushPendingSettings()   // don't lose a change made just before leaving
            }
        }
    }
}

/// Owns the model so push callbacks (token registration, taps) can reach it.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await model.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push registration failed: \(error.localizedDescription)")
    }

    // The notification delegate methods are nonisolated: the system doesn't promise to call them
    // on the main thread, so anything that touches the model hops there explicitly.

    // Show alerts even while the app is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Tapping an alert opens its story; tapping "brief ready" opens the app on Today.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let link = response.notification.request.content.userInfo["url"] as? String
        Task { @MainActor in
            if let link, let url = URL(string: link) {
                model.pendingURL = url
            }
            await model.refresh()
        }
        completionHandler()
    }
}
