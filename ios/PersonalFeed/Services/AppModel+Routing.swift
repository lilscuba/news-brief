import Foundation
import SwiftUI

/// Navigation that the model drives: articles, tapped notifications and jumps between tabs.
extension AppModel {
    // MARK: Articles

    /// Opens a story's article (its lead source unless `source` is given) in the in-app browser,
    /// marks the story read, adds it to Recently read and learns from it.
    func openArticle(_ story: Story, source: Source? = nil, reader: Bool? = nil) {
        guard let target = source ?? story.sources.first, target.url.isWebPage else { return }
        swipeTip = nil
        presentedArticle = ArticleLink(url: target.url, reader: reader ?? ArticleLink.prefersReader,
                                       storyID: story.id)
        articleStory = story
        noteOpened(story, signal: .readArticle, outlet: target.shortOutlet)
    }

    func openArticle(url: URL, reader: Bool? = nil) {
        guard url.isWebPage else { return }
        swipeTip = nil
        presentedArticle = ArticleLink(url: url, reader: reader ?? ArticleLink.prefersReader, storyID: nil)
        articleStory = nil
    }

    /// The article browser closed (RootView calls this from more than one place; only the first
    /// counts). After a story's article, offer the swipe-to-save tip, unless it's asleep, turned
    /// off, or the story is already saved.
    func articleDidClose() {
        // Another article already open: its own close offers the tip.
        guard presentedArticle == nil, let story = articleStory else { return }
        articleStory = nil
        guard phase == .ready, !isSaved(story) else { return }
        let at = now()
        guard SwipeTip.isDue(now: at, lastShown: LocalStore.swipeTipShownAt,
                             disabled: LocalStore.swipeTipDisabled) else { return }
        LocalStore.swipeTipShownAt = at  // asleep for the next 30 minutes
        swipeTip = SwipeTipPrompt(story: story)
    }

    /// Closes the tip; `forever` is "Don't show again".
    func dismissSwipeTip(forever: Bool = false) {
        if forever { LocalStore.swipeTipDisabled = true }
        swipeTip = nil
    }

    /// Opens a story's page on the stack of `tab` (story rows open this way; see StorySwipe).
    /// `day` is the past brief it was listed in. A second tap on the same story within a second
    /// (while the page slides in) is ignored.
    func push(_ story: Story, day: String? = nil, in tab: AppTab) {
        let at = now()
        if let last = lastPush, last.id == story.id, abs(at.timeIntervalSince(last.at)) < 1 { return }
        lastPush = (story.id, at)
        swipeTip = nil
        switch tab {
        case .saved:
            if let day { savedPath.append(PastStoryDestination(story: story, day: day)) } else { savedPath.append(story) }
        case .today, .settings:
            if let day { todayPath.append(PastStoryDestination(story: story, day: day)) } else { todayPath.append(story) }
        }
    }

    /// Shows a story's page on the Today tab, from anywhere.
    func showStory(_ story: Story) {
        presentedArticle = nil
        articleStory = nil
        selectedTab = .today
        todayPath.append(story)
    }

    /// Today at the top: pop pushed pages, apply a held brief and ask the list to scroll up.
    func showTodayTop() {
        presentedArticle = nil
        articleStory = nil
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
        articleStory = nil
        swipeTip = nil
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
                noteOpened(story, signal: nil)
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
