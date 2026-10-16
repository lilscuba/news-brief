import Foundation
import SwiftUI

/// Navigation that the model drives: articles, tapped notifications and jumps between tabs.
extension AppModel {
    // MARK: Articles

    /// Opens a story's article (its lead source unless `source` is given) in the in-app browser,
    /// marks the story read and adds it to Recently read.
    func openArticle(_ story: Story, source: Source? = nil, reader: Bool? = nil) {
        guard let target = source ?? story.sources.first, target.url.isWebPage else { return }
        presentedArticle = ArticleLink(url: target.url, reader: reader ?? ArticleLink.prefersReader,
                                       storyID: story.id)
        noteOpened(story)
    }

    func openArticle(url: URL, reader: Bool? = nil) {
        guard url.isWebPage else { return }
        presentedArticle = ArticleLink(url: url, reader: reader ?? ArticleLink.prefersReader, storyID: nil)
    }

    /// Shows a story's page on the Today tab, from anywhere.
    func showStory(_ story: Story) {
        presentedArticle = nil
        selectedTab = .today
        todayPath.append(story)
    }

    /// Today at the top: pop pushed pages, apply a held brief and ask the list to scroll up.
    func showTodayTop() {
        presentedArticle = nil
        selectedTab = .today
        todayPath = NavigationPath()
        clearSearch()
        applyPendingBrief()
        scrollToTopRequest += 1
    }

    func clearSearch() {
        searchQuery = ""
        isSearchPresented = false
        searchScope = .mine
    }

    // MARK: Notifications

    /// A tapped notification. Acted on once the app is signed in, restored and has checked for
    /// news (a cold launch from a push gets here before any of that).
    func handleNotification(_ route: NotificationRoute) {
        pendingRoute = route
        Task { await processPendingRoute() }
    }

    func processPendingRoute() async {
        guard let route = pendingRoute, phase == .ready, initialRefreshDone else { return }
        pendingRoute = nil
        // Close any open article first: a second sheet can't present over it.
        presentedArticle = nil
        selectedTab = .today
        todayPath = NavigationPath()
        // A push means the server just published; the cached feed may be hours old.
        if !(lastCheckedAt.map { now().timeIntervalSince($0) < 30 } ?? false) {
            await refresh(reason: .push)
        }
        applyPendingBrief()
        switch route {
        case .today:
            clearSearch()  // the list, not old search results
            scrollToTopRequest += 1
        case .story(let id, let url):
            // Switching tabs and pushing in the same update can drop the push on iOS 17.
            await Task.yield()
            if let story = resolveStory(id: id, url: url) {
                todayPath.append(story)
                noteOpened(story)
            } else if let url {
                openArticle(url: url)
            }
        }
    }

    /// Finds an alert's story: in the brief, then anywhere in the feed (an alert can be for a
    /// topic the reader doesn't follow or outside the 24 h window), then by its article URL, since
    /// alerts are clustered over a different window and the ids don't always match.
    func resolveStory(id: String?, url: URL?) -> Story? {
        let stories = brief?.allStories ?? []
        if let id {
            if let story = stories.first(where: { $0.id == id }) { return story }
            if let s = feed?.stories.first(where: { $0.id == id }) {
                return BriefBuilder.story(from: s, settings: settings)
            }
        }
        if let url {
            if let story = stories.first(where: { $0.sources.contains { $0.url == url } }) { return story }
            if let s = feed?.stories.first(where: { $0.sources.contains { $0.url == url } }) {
                return BriefBuilder.story(from: s, settings: settings)
            }
        }
        return nil
    }
}

extension URL {
    /// An http(s) page. The in-app browser can't open anything else (SFSafariViewController throws
    /// on other schemes), and a feed could send a javascript: or data: link.
    var isWebPage: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
