#if DEBUG
import Foundation
import SwiftUI

/// Simulator checks without signing in. Launch with `-BriefDemo` to skip sign-in (default settings
/// with every topic followed, the public live feed, a throwaway store) and optionally
/// `-BriefDemoRoute <route>` to open a screen once the feed has loaded:
///
///   today, saved, settings, search:<query>, topic:<Name>, story:first, story:top, story:single,
///   story:multi, article:first, new
///
/// e.g. `xcrun simctl launch booted com.lilscuba.brief -BriefDemo -BriefDemoRoute topic:US`.
enum DemoMode {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-BriefDemo") }

    static var route: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-BriefDemoRoute"), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
}

extension AppModel {
    func startDemo() async {
        isDemo = true
        // A fresh store each launch, away from any real account's data.
        let dir = FileManager.default.temporaryDirectory.appending(path: "BriefDemo", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
        LocalStore.directory = dir
        if let demoDefaults = UserDefaults(suiteName: "BriefDemo") {
            demoDefaults.removePersistentDomain(forName: "BriefDemo")
            LocalStore.defaults = demoDefaults
        }
        historyStore = HistoryStore()
        tokenStore = TokenStore(load: { nil }, save: { _ in }, delete: {})
        var everything = UserSettings.default
        everything.categories = UserSettings.allCategories
        LocalStore.settings = everything
        LocalStore.onboarded = true
        await restoreCore()
        enterDemo(settings: everything)
        sceneIsActive = UIApplication.shared.applicationState == .active
        await refresh(reason: .launch)
        if let feed {
            // The previous "visit" ended two hours before the feed was built, and stories were first
            // seen when published, so the newest ones show as new. Stored, not just set, so the next
            // scene activation doesn't reset it.
            let lastVisit = feed.generatedAt.addingTimeInterval(-2 * 3600)
            LocalStore.lastVisitAt = lastVisit
            previousVisitAt = lastVisit
            firstSeen = Dictionary(feed.stories.map { ($0.id, $0.published) }, uniquingKeysWith: { a, _ in a })
            rebuild()
            seedDemoReading()
        }
        initialRefreshDone = true
        startAutoRefreshIfActive()
        await Task.yield()
        if let route = DemoMode.route { applyDemoRoute(route) }
    }

    /// A couple of saved and read stories so Saved and the read styling have something to show.
    private func seedDemoReading() {
        guard let brief else { return }
        let stories = brief.allStories
        for story in stories.dropFirst(1).prefix(2) { setSaved(story, true) }
        for story in brief.sections.compactMap(\.stories.first).prefix(3) { noteOpened(story) }
    }

    func applyDemoRoute(_ route: String) {
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let argument = parts.count > 1 ? parts[1] : ""
        let stories = brief?.allStories ?? []
        switch name {
        case "today":
            showTodayTop()
        case "saved":
            selectedTab = .saved
        case "settings":
            selectedTab = .settings
        case "search":
            selectedTab = .today
            searchScope = .all
            isSearchPresented = true
            searchQuery = argument
        case "topic":
            selectedTab = .today
            todayPath.append(TopicDestination(name: argument))
        case "story":
            let story: Story? = switch argument {
            case "top": brief?.top.first
            case "single": stories.first { $0.sources.count == 1 }
            case "multi": stories.max { $0.outletCount < $1.outletCount }
            default: brief?.sections.first { !$0.stories.isEmpty }?.stories.first ?? stories.first
            }
            if let story { showStory(story) }
        case "article":
            if let story = brief?.top.first ?? stories.first { openArticle(story) }
        case "new":
            selectedTab = .today
            todayPath.append(NewStoriesDestination())
        default:
            break
        }
    }
}
#endif
