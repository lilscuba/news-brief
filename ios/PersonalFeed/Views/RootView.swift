import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .restoring:
                LaunchView()
            case .signedOut:
                SignInView()
            case .onboarding:
                OnboardingView()
            case .ready:
                MainTabs()
            }
        }
        .animation(.default, value: model.phase)
        // The one place articles are presented (AppModel.openArticle), so two never compete.
        // Full screen: articles are long reads, and a sheet's swipe-down fought the page's scrolling.
        .fullScreenCover(item: $model.presentedArticle) { link in
            // Safari's Close button dismisses the cover from UIKit; make sure the model hears of
            // it (from the delegate, and on disappear whatever closed it), or opening the same
            // article again would do nothing.
            ArticleBrowser(link: link, onDone: { closeArticle(link) })
                .ignoresSafeArea()
                .onDisappear { closeArticle(link) }
        }
    }

    private func closeArticle(_ link: ArticleLink) {
        if model.presentedArticle == link { model.presentedArticle = nil }
    }
}

/// The app's glyph while the account and cached brief load (usually a moment); "Loading your
/// brief…" only if that takes long enough to notice.
struct LaunchView: View {
    @State private var showsProgress = false
    @ScaledMetric(relativeTo: .largeTitle) private var glyph: CGFloat = 64

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "newspaper.fill")
                .font(.system(size: glyph * 0.55, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: glyph * 1.4, height: glyph * 1.4)
                .background(Color.accentColor.gradient,
                            in: RoundedRectangle(cornerRadius: glyph * 0.32, style: .continuous))
                .accessibilityHidden(true)
            ProgressView("Loading your brief…")
                .opacity(showsProgress ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The launch screen's colour, so the glyph appears without a flash.
        .background(Color(.systemBackground))
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation { showsProgress = true }
        }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "newspaper") }
                .tag(AppTab.today)
            SavedView()
                .tabItem { Label("Saved", systemImage: "bookmark") }
                .tag(AppTab.saved)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        // The icon's new-story count is about Today; once Today is on screen it has been seen.
        .onChange(of: model.selectedTab, initial: true) { _, tab in
            if tab == .today { model.clearBadge() }
        }
    }
}

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(RecentSearches.storageKey) private var recentSearches = ""

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.todayPath) {
            TodayContent()
                .navigationTitle("Today")
                .searchable(text: $model.searchQuery,
                            isPresented: $model.isSearchPresented,
                            placement: .navigationBarDrawer(displayMode: .automatic),
                            prompt: "Search stories and outlets")
                .searchScopes($model.searchScope) {
                    ForEach(SearchScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .searchSuggestions { RecentSearchSuggestions() }
                // Here, beside .searchable: a submit action below it never reaches the search field.
                .onSubmit(of: .search) {
                    let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !query.isEmpty { recentSearches = RecentSearches.adding(query, to: recentSearches) }
                }
                // Registered once, here at the stack root; every push is a value.
                .navigationDestination(for: Story.self) { StoryDetailView(story: $0) }
                .navigationDestination(for: PastStoryDestination.self) { StoryDetailView(story: $0.story, day: $0.day) }
                .navigationDestination(for: TopicDestination.self) { TopicPageView(destination: $0) }
                .navigationDestination(for: NewStoriesDestination.self) { _ in NewStoriesView() }
        }
    }
}

/// Today's brief, search results while there's a query, placeholders while the cached brief loads.
private struct TodayContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !StorySearch.tokens(model.searchQuery).isEmpty {
            SearchResultsView()
        } else if let brief = model.brief {
            BriefView(brief: brief, isLive: true)
        } else if model.isRestoringCache || model.isRefreshing {
            PlaceholderBrief()
        } else {
            ContentUnavailableView {
                Label("No news yet", systemImage: "tray")
            } description: {
                Text(model.feedStatus?.message ?? "Your brief appears here as soon as it's ready.")
            } actions: {
                Button("Try Again") { Task { await model.refresh(reason: .user) } }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// Grey rows in the shape of the brief while it loads, instead of a bare spinner.
struct PlaceholderBrief: View {
    private static let sample = Story(id: "placeholder", title: "A headline that runs about this long, over two lines",
                                      summary: "A summary line that gives the gist of the story.",
                                      importance: 1, label: nil, category: "Top stories", published: .now,
                                      outletCount: 1, sources: [])

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MONDAY, OCTOBER 5").font(.caption.weight(.semibold))
                    Text("Checking for news…").font(.footnote)
                    Text("120 stories from 80 sources").font(.title3.weight(.semibold))
                }
                .padding(.vertical, 6)
            }
            ForEach(0..<3, id: \.self) { _ in
                Section {
                    ForEach(0..<3, id: \.self) { _ in StoryRow(story: Self.sample) }
                } header: {
                    TopicHeader(name: BriefView.topTitle)
                }
            }
        }
        .listStyle(.insetGrouped)
        .redacted(reason: .placeholder)
        .disabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your brief")
    }
}
