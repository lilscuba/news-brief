import SwiftUI

/// One day's brief as a single scrolling feed, like a Reddit front page: every followed topic
/// mixed together and ranked (top stories first), each story a card with its picture. Above it,
/// the date, how fresh the news is and what's new since the last visit. The topic chips, or the
/// filter menu in the navigation bar, narrow the feed to one topic; the menu also hides read
/// stories, edits topics and browses the ones not followed.
///
/// Today shows the live brief (`isLive`): freshness, new markers, held updates and pull to
/// refresh. Saved > Past briefs shows an older day with the same layout.
struct BriefView: View {
    @Environment(AppModel.self) private var model
    let brief: Brief
    let isLive: Bool
    @AppStorage(StorySort.storageKey) private var sort: StorySort = .hot
    @AppStorage(BriefView.hideReadKey) private var hideRead = false
    /// The topic the feed is narrowed to; nil shows every topic.
    @State private var topic: String?
    /// A past brief's stories read before it was opened; only these are hidden. Today keeps its
    /// snapshot on the model (`todayReadSnapshot`), per visit.
    @State private var readSnapshot: Set<String>?
    @State private var editingTopics = false
    @State private var toast: Toast?

    static let hideReadKey = "hideRead"
    static let topTitle = "Top stories"
    static let headerID = "brief-header"

    init(brief: Brief, isLive: Bool = false) {
        self.brief = brief
        self.isLive = isLive
    }

    private var hiddenIDs: Set<String>? {
        hideRead ? ((isLive ? model.todayReadSnapshot : readSnapshot) ?? []) : nil
    }

    /// Hides what has been read so far: when the feed first appears, on pull to refresh and when
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
        let content = FeedContent.make(brief: brief, topic: topic, sort: sort, hiddenIDs: hiddenIDs,
                                       isRead: model.isRead)
        let topIDs = Set(brief.top.map(\.id))
        let selection = Binding(get: { content.topic }, set: { topic = $0 })

        ScrollViewReader { proxy in
            List {
                header
                    .id(Self.headerID)
                    .listRowSeparator(.hidden)
                    // Tells the model whether the reader is at the top, where an update can be shown
                    // at once instead of being held behind the "N new stories" button.
                    .onAppear { if isLive { model.todayIsAtTop = true } }
                    .onDisappear { if isLive { model.todayIsAtTop = false } }

                if content.filters.count > 1 {
                    TopicChips(filters: content.filters, selection: selection)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 12, trailing: 0))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }

                if brief.sections.isEmpty && brief.top.isEmpty {
                    noTopicsState
                } else if content.allCaughtUp {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                           description: Text("You've read everything here. Read stories are hidden."))
                        .listRowSeparator(.hidden)
                } else if content.stories.isEmpty {
                    ContentUnavailableView("Nothing new yet",
                                           systemImage: "tray",
                                           description: Text("New stories show up here as they come in."))
                        .listRowSeparator(.hidden)
                }

                ForEach(content.stories) { story in
                    FeedRow(story: story, isTop: topIDs.contains(story.id), showsTopic: content.topic == nil,
                            hidesDealLabel: content.topic == "Deals", day: isLive ? nil : brief.date)
                }

                if isLive && content.topic == nil { alsoAvailableSection }

                footer
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .minuteClock()
            .overlay(alignment: .top) { pendingButton(proxy) }
            .onChange(of: model.scrollToTopRequest) {
                if isLive { scrollToTop(proxy) }
            }
            .onChange(of: topic) { proxy.scrollTo(Self.headerID, anchor: .top) }
            .onChange(of: sort) { proxy.scrollTo(Self.headerID, anchor: .top) }
            .sensoryFeedback(.selection, trigger: topic)
        }
        .toolbar {
            if isLive || content.filters.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { filterMenu(content.filters, selection: selection) }
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

    private var header: some View {
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
            // Floats over the feed: past this size it would cover the cards it's announcing.
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

    // MARK: Below the feed

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
        .listRowSeparator(.hidden)
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
            Text("Headlines, snippets and pictures come straight from each source.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 12)
    }

    // MARK: Filter menu

    /// Pick a topic or the sort order from anywhere in the feed, without scrolling back up to the
    /// chips; hide read stories, edit topics, or browse one you don't follow.
    private func filterMenu(_ filters: [TopicFilter], selection: Binding<String?>) -> some View {
        Menu {
            Picker("Topic", selection: selection) {
                Label("All topics", systemImage: "square.stack").tag(String?.none)
                ForEach(filters) { filter in
                    let new = isLive ? brief.stories(inTopic: filter.name).filter(model.isNew).count : 0
                    Label(TopicHeader.menuTitle(filter.name, count: filter.count, newCount: new),
                          systemImage: TopicStyle.of(filter.name).symbol)
                        .tag(String?.some(filter.name))
                }
            }
            Picker("Sort stories by", selection: $sort) {
                ForEach(StorySort.allCases) { option in
                    Text(option.title).tag(option)
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
                    // Value links, like every other push here. A separate bound
                    // navigationDestination(item:) on the same stack left the article links on that
                    // topic page highlighted but not opening until the next tap.
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
            Label("Filter", systemImage: selection.wrappedValue == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
    }
}

/// What the feed shows: every followed topic mixed together (top stories first, then by score),
/// or one topic; in the chosen order; minus stories read before the feed appeared when "Hide read"
/// is on.
struct FeedContent: Equatable {
    let stories: [Story]
    /// Topics with stories, for the chips and the filter menu.
    let filters: [TopicFilter]
    /// The topic in effect: nil for all, and a topic that was since unfollowed (or that a past brief
    /// doesn't have) shows everything.
    let topic: String?
    /// Hide read is on and everything that would be shown has been read.
    let allCaughtUp: Bool

    static func make(brief: Brief, topic: String?, sort: StorySort, hiddenIDs: Set<String>?,
                     isRead: (Story) -> Bool) -> FeedContent {
        let all = brief.stories
        let filters = TopicFilter.counts(in: all, order: brief.sections.map(\.name))
        let selected = topic.flatMap { name in filters.contains { $0.name == name } ? name : nil }
        let inTopic = selected.map { name in all.filter { $0.category == name } } ?? all
        let shown = HideRead.visible(sort.apply(inTopic), hidden: hiddenIDs)
        let caughtUp = hiddenIDs != nil && shown.isEmpty && !inTopic.isEmpty && inTopic.allSatisfy(isRead)
        return FeedContent(stories: shown, filters: filters, topic: selected, allCaughtUp: caughtUp)
    }
}

/// A story card that opens the story, with the same actions as a list row: swipe to mark read or
/// save, long-press for the menu and a preview. The link is hidden so the card has no disclosure
/// chevron; a tap anywhere on the card still opens it.
private struct FeedRow: View {
    @Environment(AppModel.self) private var model
    let story: Story
    let isTop: Bool
    let showsTopic: Bool
    let hidesDealLabel: Bool
    let day: String?

    var body: some View {
        let read = model.isRead(story)
        let saved = model.isSaved(story)
        ZStack {
            Group {
                if let day {
                    NavigationLink(value: PastStoryDestination(story: story, day: day)) { EmptyView() }
                } else {
                    NavigationLink(value: story) { EmptyView() }
                }
            }
            .opacity(0)
            StoryCard(story: story, isTop: isTop, isRead: read, isNew: model.isNew(story), isSaved: saved,
                      showsTopic: showsTopic, hidesDealLabel: hidesDealLabel)
        }
        .listRowInsets(EdgeInsets())
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .swipeActions(edge: .leading) {
            Button {
                model.setRead(story, !read)
            } label: {
                Label(read ? "Unread" : "Read", systemImage: read ? "envelope.badge" : "envelope.open")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button {
                model.setSaved(story, !saved)
            } label: {
                Label(saved ? "Unsave" : "Save", systemImage: saved ? "bookmark.slash" : "bookmark")
            }
            .tint(.orange)
        }
        .contextMenu {
            StoryMenuItems(story: story, isRead: read, isSaved: saved)
        } preview: {
            StoryPreviewCard(story: story)
        }
        .accessibilityAction(named: "Read article") { model.openArticle(story) }
    }
}

/// A followed topic that has stories in the feed, shown as a chip.
struct TopicFilter: Identifiable, Hashable {
    let name: String
    let count: Int
    var id: String { name }

    /// Topics in `order` (the brief's topic order) with at least one story, and how many.
    static func counts(in stories: [Story], order: [String]) -> [TopicFilter] {
        let counts = Dictionary(grouping: stories, by: \.category).mapValues(\.count)
        return order.compactMap { name in counts[name].map { TopicFilter(name: name, count: $0) } }
    }
}

/// "All" plus one chip per topic, scrolling sideways. Tapping the selected chip again goes back
/// to All.
struct TopicChips: View {
    let filters: [TopicFilter]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, title: "All", symbol: "square.stack.fill", color: .accentColor, count: nil)
                ForEach(filters) { filter in
                    let style = TopicStyle.of(filter.name)
                    chip(filter.name, title: filter.name, symbol: style.symbol, color: style.color,
                         count: filter.count)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ name: String?, title: String, symbol: String, color: Color, count: Int?) -> some View {
        let isSelected = selection == name
        return Button {
            selection = isSelected ? nil : name
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .imageScale(.small)
                Text(title)
                if let count {
                    Text("\(count)")
                        .monospacedDigit()
                        .opacity(0.7)
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)),
                        in: Capsule())
        }
        // Without this, a tap anywhere in the row would fire every chip's button.
        .buttonStyle(.plain)
        .accessibilityLabel(count.map { "\(title), \($0) stories" } ?? "All topics")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One story in the feed, laid out like a Reddit post: what it is (topic, notable label, outlet,
/// age), the headline, the picture (or the snippet when there isn't one) and how widely it's
/// covered. New stories get a dot and read ones a check, like the list rows.
struct StoryCard: View {
    let story: Story
    var isTop = false
    var isRead = false
    var isNew = false
    var isSaved = false
    /// The mixed feed names each story's topic; a feed narrowed to one topic doesn't repeat it.
    var showsTopic = true
    var hidesDealLabel = false

    @Environment(\.listClock) private var clock
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var markerSize: CGFloat = 8

    var body: some View {
        let now = clock ?? .now
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                marker
                if showsTopic {
                    TopicIcon(name: story.category, size: 20)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                caption(now: now)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(story.title)
                .font(isRead ? .headline.weight(.regular) : .headline)
                .foregroundStyle(isRead ? .secondary : .primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let image = story.image {
                StoryImage(url: image, topic: story.category)
            } else if story.hasUsefulSummary && !typeSize.isAccessibilitySize {
                Text(story.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if isTop || story.outletCount > 1 {
                HStack(spacing: 8) {
                    if isTop {
                        Label("Top story", systemImage: "flame.fill")
                            .foregroundStyle(.orange)
                            .pill()
                    }
                    if story.outletCount > 1 {
                        Label("\(story.outletCount) outlets", systemImage: "newspaper")
                            .pill()
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StoryCaption.spokenTitle(story))
        .accessibilityValue((isTop ? "Top story, " : "")
                            + StoryCaption.spokenDetails(story, isRead: isRead, isNew: isNew, isSaved: isSaved,
                                                         showsTopic: showsTopic, now: now))
        .accessibilityCustomContent(AccessibilityCustomContentKey("Summary"),
                                    story.hasUsefulSummary ? Text(story.summary) : nil)
    }

    /// "Tech · ⚠ Credible rumor · The Verge · 2h ago" as one Text, so it wraps at large sizes. The
    /// outlet count is in the pill below, so the caption names only the lead outlet.
    private func caption(now: Date) -> Text {
        let line = StoryCaption.text(story, showsTopic: false, hidesDealLabel: hidesDealLabel, isSaved: isSaved,
                                     showsCoverage: false, now: now)
        guard showsTopic else { return line }
        return Text("\(Text(story.category).fontWeight(.semibold).foregroundStyle(.primary))\u{00A0}· \(line)")
    }

    /// A tinted dot for new, a check for read, nothing for the rest.
    @ViewBuilder
    private var marker: some View {
        if isNew {
            Circle()
                .fill(Color.accentColor)
                .frame(width: markerSize, height: markerSize)
        } else if isRead {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }
}

private extension View {
    /// The grey capsule under a card, like the vote and comment counts under a Reddit post.
    func pill() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
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

/// "Hide read stories": lists hide what was read before they appeared, so a story you just opened
/// stays put when you come back to the list and goes on the next visit or refresh.
enum HideRead {
    static func visible(_ stories: [Story], hidden: Set<String>?) -> [Story] {
        guard let hidden, !hidden.isEmpty else { return stories }
        return stories.filter { !hidden.contains($0.id) }
    }
}

/// The Topics editor from Settings, opened from Today's filter menu.
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
    /// At the default text size; it grows and shrinks with the reader's text size.
    var baseSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title3) private var scale: CGFloat = 1

    init(name: String, size: CGFloat = 28) {
        self.name = name
        baseSize = size
    }

    var body: some View {
        let size = baseSize * scale
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

    /// "US · 241" or "US · 241 · 5 new" in the filter menu.
    static func menuTitle(_ name: String, count: Int, newCount: Int) -> String {
        newCount > 0 ? "\(name) · \(count) · \(newCount) new" : "\(name) · \(count)"
    }
}
