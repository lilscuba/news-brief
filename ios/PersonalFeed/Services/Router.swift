import Foundation

// Navigation state lives on AppModel (selectedTab, todayPath, savedPath, presentedArticle) so push
// taps and the model can drive it. Every push is a value: views use NavigationLink(value:) or
// append to a bound path, with navigationDestination(for:) registered once at each stack root.

enum AppTab: String, Hashable, Codable, Sendable {
    case today, saved, settings
}

/// A topic page. `day` nil means today's live brief; otherwise a past brief's yyyy-MM-dd.
struct TopicDestination: Hashable, Codable, Sendable {
    let name: String
    var day: String? = nil
}

/// A story opened from a past brief: its page lists that day's topic, not today's.
struct PastStoryDestination: Hashable, Codable, Sendable {
    let story: Story
    let day: String
}

/// The "N new since 9:40 AM" list.
struct NewStoriesDestination: Hashable, Codable, Sendable {}

/// A past day's brief, opened from Past briefs.
struct PastBriefDestination: Hashable, Codable, Sendable {
    let date: String
}

/// An article to show in the in-app browser. `presentedArticle` is the only place articles are
/// presented, so two sheets never compete (a push tap while an article is open used to do nothing).
struct ArticleLink: Identifiable, Hashable, Sendable {
    /// The Settings "Open articles in Reader view" switch (@AppStorage, default on).
    static let readerModeKey = "openArticlesInReader"

    let url: URL
    /// Open in Reader view when the page supports it.
    var reader: Bool
    /// The story it belongs to, if any.
    var storyID: String?
    var id: URL { url }

    static var prefersReader: Bool {
        UserDefaults.standard.object(forKey: readerModeKey) as? Bool ?? true
    }
}

enum SearchScope: String, CaseIterable, Hashable, Sendable, Identifiable {
    case mine, all
    var id: String { rawValue }
    var title: String { self == .mine ? "My topics" : "All topics" }
}

/// What a tapped notification asks for. Held until the app is signed in, restored and has
/// checked for news, then acted on by `AppModel.processPendingRoute()`.
enum NotificationRoute: Equatable, Sendable {
    /// "Your brief is ready": Today, at the top.
    case today
    /// A breaking alert: open its story inside the app; the URL is the fallback.
    case story(id: String?, url: URL?)

    init(kind: String?, storyID: String?, url: URL?) {
        if kind == "brief" || (storyID == nil && url == nil) {
            self = .today
        } else {
            self = .story(id: storyID, url: url)
        }
    }

    /// Reads the APNs payload keys set by briefing/apns.py: kind, storyId, url.
    init(userInfo: [AnyHashable: Any]) {
        self.init(kind: userInfo["kind"] as? String,
                  storyID: userInfo["storyId"] as? String,
                  url: (userInfo["url"] as? String).flatMap(URL.init(string:)))
    }
}
