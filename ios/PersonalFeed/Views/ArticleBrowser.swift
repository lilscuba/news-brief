import SafariServices
import SwiftUI
import UIKit

/// The in-app browser. RootView presents it full screen for `AppModel.presentedArticle`, the one
/// place articles open. Reader view is decided per article (`ArticleLink.reader`), so "Open
/// without Reader" can rescue a page Reader mangles without changing the setting. It also honors
/// any Safari content blocker installed on the phone.
struct ArticleBrowser: UIViewControllerRepresentable {
    let link: ArticleLink
    /// Safari's Close button. UIKit dismisses the browser itself, so the model has to be told, or
    /// opening the same article again would do nothing.
    var onDone: () -> Void = {}

    static func configuration(reader: Bool) -> SFSafariViewController.Configuration {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = reader
        config.barCollapsingEnabled = true
        return config
    }

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: link.url, configuration: Self.configuration(reader: link.reader))
        controller.dismissButtonStyle = .close
        // The app's tint: system blue (the orange AccentColor asset isn't the app's accent).
        controller.preferredControlTintColor = .systemBlue
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        context.coordinator.onDone = onDone
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency SFSafariViewControllerDelegate {
        var onDone: () -> Void

        init(onDone: @escaping () -> Void) {
            self.onDone = onDone
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDone()
        }
    }
}
