import SwiftUI
import UIKit
import UserNotifications

@main
struct PersonalFeedApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        let model = delegate.model
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    // Unit tests run inside the app; they build their own models and stores.
                    guard !AppDelegate.isHostingTests else { return }
                    await model.restore()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active: model.sceneDidBecomeActive()
            case .inactive: model.sceneWillResignActive()
            case .background: model.sceneDidEnterBackground()
            @unknown default: break
            }
        }
        // iOS wakes the app now and then to check for news (scheduled when it goes to the
        // background), so a later open starts from a fresh brief and the badge can count what's new.
        .backgroundTask(.appRefresh(AppModel.backgroundRefreshID)) {
            await model.backgroundRefresh()
        }
    }
}

/// Owns the model so push callbacks (token registration, taps) can reach it.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    let model = AppModel()

    static var isHostingTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

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
        AppModel.log.error("Push registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // Show alerts even while the app is open. A push means the server just published, so check
    // for news too; Today offers it as "N new stories" rather than reshuffling under the reader.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if model.phase == .ready { Task { await model.refresh(reason: .push) } }
        completionHandler([.banner, .sound])
    }

    // Tapping an alert opens its story on Today; tapping "brief ready" opens Today at the top.
    // On a cold launch this arrives before the app is restored; the model holds it until then.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        model.handleNotification(NotificationRoute(userInfo: response.notification.request.content.userInfo))
        completionHandler()
    }
}
