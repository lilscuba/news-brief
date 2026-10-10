import SwiftUI

/// One day's brief as a single scrolling feed: the date and how fresh it is, Top stories, then a
/// short preview of every followed topic with a "See all" page. A "Topics" menu in the navigation
/// bar opens one, hides read stories, edits topics and browses the ones not followed.
///
/// Today shows the live brief (`isLive`): freshness, new markers, held updates and pull to
/// refresh. Saved > Past briefs shows an older day with the same layout.
struct BriefView: View {
    @Environment(AppModel.self) private var model
    let brief: Brief
    let isLive: Bool
    @AppStorage(StorySort.storageKey) private var sort: StorySort = .hot
    @AppStorage(BriefView.hideReadKey) private var hideRead = false
    /// A past brief's stories read before it was opened; only these are hidden. Today keeps its
    /// snapshot on the model (`todayReadSnapshot`), per visit.
    @State private var readSnapshot: Set<String>?
    @State private var editingTopics = false
    @State private var toast: Toast?

    /// Stories shown per topic in the feed before "See all".
    static let previewCount = 3
    static let hideReadKey = "hideRead"
    static let topTitle = "Top stories"
    static let headerID = "brief-header"

    init(brief: Brief, isLive: Bool = false) {
        self.brief = brief
        self.isLive = isLive
    }

    /// Topic pages of today's live brief follow refreshes; a past brief's pages stay on that day.
    private func destination(_ name: String) -> TopicDestination {
        TopicDestination(name: name, day: isLive ? nil : brief.date)
    }

    private var hiddenIDs: Set<String>? {
        hideRead ? ((isLive ? model.todayReadSnapshot : readSnapshot) ?? []) : nil
    }

    /// Hides what has been read so far: when the list first appears, on pull to refresh and when
    /// "Hide read stories" is switched on. Never on an automatic update, so nothing just read vanishes.
    private func takeReadSnapshot(onlyIfMissing: Bool = false) {
        let read = Set(model.readAt.keys)
        if isLive {
            if !onlyIfMissing || model.todayReadSnapshot == nil { model.todayReadSnapshot = read }
        } else if !onlyIfMissing || readSnapshot == nil {
            readSnapshot = read
        }
    }

    var body: some View {
        let topics = brief.topicsWithStories
        let top = HideRead.visible(sort.apply(brief.top), hidden: hiddenIDs)
        ScrollViewReader { proxy in
            List {
                headerSection

                if brief.sections.isEmpty && brief.top.isEmpty {
                    noTopicsState
                } else if topics.isEmpty && brief.top.isEmpty {
                    ContentUnavailableView("Nothing new yet",
                                           systemImage: "tray",
                                           description: Text("New stories show up here as they come in."))
                        .listRowBackground(Color.clear)
                }

                if !top.isEmpty {
                    Section {
                        ForEach(top) { story in
                            StoryLink(story: story, showsTopic: true, day: isLive ? nil : brief.date)
                        }
                    } header: {
                        TopicHeader(name: Self.topTitle)
                    }
                }

                ForEach(topics, id: \.self) { name in
                    topicSection(name)
                }

                if isLive { alsoAvailableSection }

                Section { footer }
            }
            .listStyle(.insetGrouped)
            .minuteClock()
            .overlay(alignment: .top) { pendingButton(proxy) }
            .onChange(of: model.scrollToTopRequest) {
                if isLive { scrollToTop(proxy) }
            }
        }
        .toolbar {
            if isLive || !topics.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { topicsMenu(topics) }
            }
        }
        .sheet(isPresented: $editingTopics) { EditTopicsSheet() }
        .modifier(LiveRefresh(isLive: isLive) { @MainActor in
            let result = await Toast.pullToRefresh(model)
            takeReadSnapshot()
            toast = result
        })
        .onAppear { takeReadSnapshot(onlyIfMissing: true) }
        .onChange(of: hideRead) { takeReadSnapshot() }
        .toast($toast)
    }

    // MARK: Header

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(brief.displayDate.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tint)
                FreshnessLine(brief: brief, isLive: isLive)
                Text(brief.headline)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if isLive { newSinceButton }
                SortPicker()
                    .padding(.top, 4)
            }
            .padding(.vertical, 6)
            .id(Self.headerID)
            // Tells the model whether the reader is at the top, where an update can be shown at
            // once instead of being held behind the "N new stories" button.
            .onAppear { if isLive { model.todayIsAtTop = true } }
            .onDisappear { if isLive { model.todayIsAtTop = false } }
        }
    }

    @ViewBuilder
    private var newSinceButton: some View {
        let count = brief.allStories.filter(model.isNew).count
        if count > 0, let since = model.previousVisitAt {
            Button {
                model.todayPath.append(NewStoriesDestination())
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text(Freshness.newSince(count: count, since: since, now: .now))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityHint("Lists the stories that arrived since your last visit")
        }
    }

    /// Shown while an automatic update is held because the reader is scrolled down.
    @ViewBuilder
    private func pendingButton(_ proxy: ScrollViewProxy) -> some View {
        if isLive, model.pendingBrief != nil {
            let count = model.pendingNewCount
            Button {
                withAnimation(.snappy) { model.applyPendingBrief() }
                scrollToTop(proxy)
            } label: {
                Label(count > 0 ? "\(count) new \(count == 1 ? "story" : "stories")" : "Show latest",
                      systemImage: "arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            // Floats over the list: past this size it would cover the rows it's announcing.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityHint("Shows the latest stories and scrolls to the top")
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        withAnimation(.snappy) { proxy.scrollTo(Self.headerID, anchor: .top) }
    }

    // MARK: Sections

    @ViewBuilder
    private func topicSection(_ name: String) -> some View {
        let all = brief.stories(inTopic: name)
        let preview = TopicPreview.make(sectionStories: brief.sections.first { $0.name == name }?.stories ?? [],
                                        topicStories: all, sort: sort, hiddenIDs: hiddenIDs,
                                        isRead: model.isRead)
        let newCount = isLive ? all.filter(model.isNew).count : 0
        let link = destination(name)
        Section {
            ForEach(preview.stories) { story in
                StoryLink(story: story, hidesDealLabel: name == "Deals", day: isLive ? nil : brief.date)
            }
            if preview.allCaughtUp {
                Label("All caught up in \(name)", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if preview.total > preview.stories.count {
                NavigationLink(value: link) {
                    Text("See all \(preview.total) in \(name)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        } header: {
            NavigationLink(value: link) {
                TopicHeader(name: name, count: preview.total, newCount: newCount, opensPage: true)
            }
            .buttonStyle(.plain)
        }
    }

    /// Topics not followed that have stories now, so the big news topics can be found from Today.
    @ViewBuilder
    private var alsoAvailableSection: some View {
        let more = moreTopics.filter { $0.count > 0 }
        if !more.isEmpty {
            Section {
                ForEach(more, id: \.name) { topic in
                    NavigationLink(value: TopicDestination(name: topic.name)) {
                        HStack(spacing: 12) {
                            TopicIcon(name: topic.name)
                            Text(topic.name)
                            Spacer(minLength: 8)
                            Text("\(topic.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("\(topic.name), \(topic.count) stories")
                }
            } header: {
                Text("Also available")
            } footer: {
                Text("Topics you don't follow. Open one to browse it, or follow it from there.")
            }
        }
    }

    /// Unfollowed topics with today's counts, in catalog order.
    private var moreTopics: [(name: String, count: Int)] {
        model.settings.unfollowedCategories.map { name in
            (name, model.allTopicsBrief?.stories(inTopic: name).count ?? 0)
        }
    }

    @ViewBuilder
    private var noTopicsState: some View {
        ContentUnavailableView {
            Label("No topics followed", systemImage: "list.bullet")
        } description: {
            Text(isLive ? "Pick the topics you want in your brief." : "This brief had no topics.")
        } actions: {
            if isLive { Button("Choose Topics") { editingTopics = true } }
        }
        .listRowBackground(Color.clear)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !brief.quietTopics.isEmpty {
                Label("Quiet right now: \(brief.quietTopics.joined(separator: ", "))", systemImage: "moon.zzz")
            }
            if !brief.sourceProblems.isEmpty {
                Label("Not responding right now: \(brief.sourceProblems.joined(separator: ", "))",
                      systemImage: "exclamationmark.circle")
            }
            Text("Headlines and snippets come straight from each source.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Topics menu

    private func topicsMenu(_ topics: [String]) -> some View {
        Menu {
            Section {
                // Value links, like every other push here. A separate bound
                // navigationDestination(item:) on the same stack left the article links on that
                // topic page highlighted but not opening until the next tap.
                ForEach(topics, id: \.self) { name in
                    let stories = brief.stories(inTopic: name)
                    let new = isLive ? stories.filter(model.isNew).count : 0
                    NavigationLink(value: destination(name)) {
                        Label(TopicHeader.menuTitle(name, count: stories.count, newCount: new),
                              systemImage: TopicStyle.of(name).symbol)
                    }
                }
            }
            Section {
                Toggle(isOn: $hideRead) {
                    Label("Hide Read Stories", systemImage: "eye.slash")
                }
                if isLive {
                    Button("Edit Topics…", systemImage: "slider.horizontal.3") { editingTopics = true }
                }
            }
            if isLive && !moreTopics.isEmpty {
                Menu {
                    ForEach(moreTopics, id: \.name) { topic in
                        NavigationLink(value: TopicDestination(name: topic.name)) {
                            Label("\(topic.name) · \(topic.count)", systemImage: TopicStyle.of(topic.name).symbol)
                        }
                    }
                } label: {
                    Label("More Topics", systemImage: "plus.circle")
                }
            }
        } label: {
            Label("Topics", systemImage: "list.bullet")
        }
    }
}

/// Pull to refresh on the live brief only; a past day has nothing to refresh.
struct LiveRefresh: ViewModifier {
    let isLive: Bool
    let action: @MainActor @Sendable () async -> Void

    func body(content: Content) -> some View {
        if isLive {
            content.refreshable { await action() }
        } else {
            content
        }
    }
}

/// What a topic's section on Today shows: up to three stories, the full count for "See all", and
/// whether everything in it has been read.
struct TopicPreview: Equatable {
    let stories: [Story]
    /// Every story of the topic, Top stories included.
    let total: Int
    /// Hide read is on and every story of the topic is read.
    let allCaughtUp: Bool

    /// `sectionStories` are the topic's stories that aren't in Top stories (Today never shows a
    /// story twice); `topicStories` all of them. `hiddenIDs` is nil when read stories are shown.
    static func make(sectionStories: [Story], topicStories: [Story], sort: StorySort, hiddenIDs: Set<String>?,
                     isRead: (Story) -> Bool, limit: Int = BriefView.previewCount) -> TopicPreview {
        let shown = HideRead.visible(sort.apply(sectionStories), hidden: hiddenIDs)
        let caughtUp = hiddenIDs != nil && shown.isEmpty && !topicStories.isEmpty && topicStories.allSatisfy(isRead)
        return TopicPreview(stories: Array(shown.prefix(limit)), total: topicStories.count, allCaughtUp: caughtUp)
    }
}

/// "Hide read stories": lists hide what was read before they appeared, so a story you just opened
/// stays put when you come back to the list and goes on the next visit or refresh.
enum HideRead {
    static func visible(_ stories: [Story], hidden: Set<String>?) -> [Story] {
        guard let hidden, !hidden.isEmpty else { return stories }
        return stories.filter { !hidden.contains($0.id) }
    }
}

/// The Topics editor from Settings, opened from Today's Topics menu.
struct EditTopicsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TopicsSection(settings: Binding(get: { model.settings }, set: { model.update($0) }),
                              saveState: model.saveState)
            }
            .topicsEditing()
            .navigationTitle("Topics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Hot topics (default) or Latest. Remembered across launches and shared by every list.
struct SortPicker: View {
    @AppStorage(StorySort.storageKey) private var sort: StorySort = .hot

    var body: some View {
        Picker("Sort stories by", selection: $sort) {
            ForEach(StorySort.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .sensoryFeedback(.selection, trigger: sort)
        .animation(.snappy, value: sort)
    }
}

/// Icon and colour for a topic.
struct TopicStyle {
    let symbol: String
    let color: Color

    static func of(_ name: String) -> TopicStyle {
        switch name {
        case BriefView.topTitle: TopicStyle(symbol: "flame.fill", color: .orange)
        case "AI": TopicStyle(symbol: "cpu", color: .purple)
        case "Tech": TopicStyle(symbol: "laptopcomputer", color: .blue)
        case "Gaming": TopicStyle(symbol: "gamecontroller.fill", color: .green)
        case "US": TopicStyle(symbol: "building.columns.fill", color: .brown)
        case "World": TopicStyle(symbol: "globe", color: .teal)
        case "Europe": TopicStyle(symbol: "globe.europe.africa.fill", color: .indigo)
        case "Japan": TopicStyle(symbol: "globe.asia.australia.fill", color: .red)
        case "Korea": TopicStyle(symbol: "globe.asia.australia.fill", color: .cyan)
        case "Deals": TopicStyle(symbol: "tag.fill", color: .pink)
        default: TopicStyle(symbol: "newspaper.fill", color: .gray)
        }
    }
}

/// A topic's coloured icon tile. Scales with the text so the glyph never outgrows the tile.
struct TopicIcon: View {
    let name: String
    @ScaledMetric(relativeTo: .title3) private var size: CGFloat = 28

    var body: some View {
        let style = TopicStyle.of(name)
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(style.color.gradient, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Section header: coloured icon, topic name, new and total counts, and a chevron when it opens a
/// page.
struct TopicHeader: View {
    let name: String
    var count: Int? = nil
    var newCount = 0
    var opensPage = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Too wide for one line at these sizes: the counts go under the name rather than
                // squeezing it to "Eur…".
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        TopicIcon(name: name)
                        title
                    }
                    HStack(spacing: 8) {
                        counts
                        chevron
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    TopicIcon(name: name)
                    title
                    Spacer(minLength: 8)
                    counts
                    chevron
                }
            }
        }
        .textCase(nil)
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(name, count: count, newCount: newCount))
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(opensPage ? "Shows every \(name) story" : "")
    }

    private var title: some View {
        Text(name)
            .font(.title3.weight(.bold))
            // Color.primary, not .primary: list headers pass down a secondary style that the
            // hierarchical .primary would inherit.
            .foregroundStyle(Color.primary)
    }

    @ViewBuilder
    private var counts: some View {
        if newCount > 0 {
            Text("\(newCount) new")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
        }
        if let count {
            Text("\(count)")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chevron: some View {
        if opensPage {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    /// "US, 241 stories, 5 new".
    static func spoken(_ name: String, count: Int?, newCount: Int) -> String {
        var parts = [name]
        if let count { parts.append("\(count) \(count == 1 ? "story" : "stories")") }
        if newCount > 0 { parts.append("\(newCount) new") }
        return parts.joined(separator: ", ")
    }

    /// "US · 241" or "US · 241 · 5 new" in the Topics menu.
    static func menuTitle(_ name: String, count: Int, newCount: Int) -> String {
        newCount > 0 ? "\(name) · \(count) · \(newCount) new" : "\(name) · \(count)"
    }
}
