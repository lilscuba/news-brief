import SwiftUI

/// Every story of one topic, Top stories included. Reads the model live, so a refresh (or a muted
/// word) shows up on an open page; today's page can be pulled to refresh. The title is a menu that
/// switches topic in place, without stacking another page.
struct TopicPageView: View {
    @Environment(AppModel.self) private var model
    let destination: TopicDestination
    /// The topic on screen; starts as the one tapped and changes from the title menu.
    @State private var current: String
    @AppStorage(StorySort.storageKey) private var sort: StorySort = .hot
    @AppStorage(BriefView.hideReadKey) private var hideRead = false
    /// Stories read before the page appeared; only these are hidden, so one just read stays put.
    @State private var readSnapshot: Set<String>?
    @State private var toast: Toast?
    @State private var loadFailed = false

    private static let topID = "topic-top"

    init(destination: TopicDestination) {
        self.destination = destination
        _current = State(initialValue: destination.name)
    }

    /// Today's topic (follows refreshes) rather than a past brief's.
    private var isLive: Bool { destination.day == nil || destination.day == model.brief?.date }

    /// A past day's brief is read from disk when the page opens.
    private var isLoaded: Bool { isLive || model.brief(for: destination.day) != nil || loadFailed }

    var body: some View {
        let all = model.stories(inTopic: current, day: destination.day)
        let hidden = hideRead ? (readSnapshot ?? []) : nil
        let visible = HideRead.visible(sort.apply(all), hidden: hidden)
        let following = model.isFollowing(current)
        let newCount = isLive ? all.filter(model.isNew).count : 0
        let next = nextTopic
        ScrollViewReader { proxy in
            List {
                Section {
                    // The scroll target for switching topics: a row, which a List can scroll to.
                    SortPicker()
                        .id(Self.topID)
                } header: {
                    Text(Self.countLine(total: all.count, newCount: newCount,
                                        hiddenCount: all.count - visible.count))
                }

                if isLive && !following {
                    followRow
                }

                if sort == .latest {
                    // Grouped by time, so a long newest-first list shows how current it is.
                    ForEach(StorySort.buckets(visible)) { bucket in
                        Section(bucket.title) { rows(bucket.stories) }
                    }
                } else if !visible.isEmpty {
                    Section { rows(visible) }
                }

                if hidden != nil && visible.isEmpty && !all.isEmpty {
                    Label("All caught up in \(current)", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }

                if let next {
                    Section {
                        Button {
                            switchTo(next.name, proxy: proxy)
                        } label: {
                            Label("Next: \(next.name) · \(next.count)", systemImage: "arrow.right.circle")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityLabel("Next topic: \(next.name), \(next.count) stories")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .minuteClock()
            .overlay {
                if !isLoaded {
                    ProgressView()
                } else if all.isEmpty {
                    emptyState
                }
            }
            .toolbarTitleMenu {
                topicSwitcher(proxy)
            }
        }
        .navigationTitle(current)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { pageMenu(all) }
        }
        .modifier(LiveRefresh(isLive: isLive) { @MainActor in
            // A pushed page counts as "scrolled down", so an automatic update may be waiting.
            let result = await Toast.pullToRefresh(model)
            readSnapshot = Set(model.readAt.keys)
            toast = result
        })
        .task(id: destination.day) {
            // A past day's brief may have been dropped from the model's small cache.
            if let day = destination.day { loadFailed = await model.loadBrief(day: day) == nil }
        }
        .onAppear { if readSnapshot == nil { readSnapshot = Set(model.readAt.keys) } }
        .onChange(of: hideRead) { readSnapshot = Set(model.readAt.keys) }
        .toast($toast)
    }

    private func rows(_ stories: [Story]) -> some View {
        ForEach(stories) { story in
            StoryLink(story: story, hidesDealLabel: current == "Deals", day: isLive ? nil : destination.day)
        }
    }

    /// "241 stories · 5 new · 30 read hidden".
    static func countLine(total: Int, newCount: Int, hiddenCount: Int) -> String {
        var parts = ["\(total) \(total == 1 ? "story" : "stories")"]
        if newCount > 0 { parts.append("\(newCount) new") }
        if hiddenCount > 0 { parts.append("\(hiddenCount) read hidden") }
        return parts.joined(separator: " · ")
    }

    // MARK: Following

    private var followRow: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("You don't follow \(current). Follow it to see it in Today and in your morning brief.")
                        .font(.subheadline)
                } icon: {
                    TopicIcon(name: current)
                }
                Button {
                    model.setFollowing(current, true)
                    toast = Toast(message: "Following \(current)", systemImage: "checkmark.circle")
                } label: {
                    Label("Follow \(current)", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Switching topics

    private struct TopicCount: Hashable {
        let name: String
        let count: Int
    }

    /// Followed topics with stories (a past day: that day's topics).
    private var followedTopics: [TopicCount] {
        guard let brief = model.brief(for: destination.day) else { return [] }
        return brief.topicsWithStories.map { TopicCount(name: $0, count: brief.stories(inTopic: $0).count) }
    }

    /// Topics not followed that have stories today, so they can be browsed.
    private var moreTopics: [TopicCount] {
        guard isLive, let everything = model.allTopicsBrief else { return [] }
        return model.settings.unfollowedCategories.compactMap { name in
            let count = everything.stories(inTopic: name).count
            return count > 0 ? TopicCount(name: name, count: count) : nil
        }
    }

    /// The followed topic after this one, for reading straight through.
    private var nextTopic: TopicCount? {
        let topics = followedTopics
        guard let i = topics.firstIndex(where: { $0.name == current }), i + 1 < topics.count else { return nil }
        return topics[i + 1]
    }

    @ViewBuilder
    private func topicSwitcher(_ proxy: ScrollViewProxy) -> some View {
        let selection = Binding(get: { current }, set: { switchTo($0, proxy: proxy) })
        Picker("Topic", selection: selection) {
            ForEach(followedTopics, id: \.self) { topic in
                Label("\(topic.name) · \(topic.count)", systemImage: TopicStyle.of(topic.name).symbol)
                    .tag(topic.name)
            }
        }
        .pickerStyle(.inline)
        let more = moreTopics
        if !more.isEmpty {
            Picker("More topics", selection: selection) {
                ForEach(more, id: \.self) { topic in
                    Label("\(topic.name) · \(topic.count)", systemImage: TopicStyle.of(topic.name).symbol)
                        .tag(topic.name)
                }
            }
            .pickerStyle(.inline)
        }
    }

    private func switchTo(_ name: String, proxy: ScrollViewProxy) {
        guard name != current else { return }
        current = name
        proxy.scrollTo(Self.topID, anchor: .top)
    }

    // MARK: Menu and empty state

    private func pageMenu(_ all: [Story]) -> some View {
        Menu {
            Toggle(isOn: $hideRead) {
                Label("Hide Read Stories", systemImage: "eye.slash")
            }
            Button("Mark All as Read", systemImage: "checkmark.circle") {
                let marked = model.markRead(all)
                guard !marked.isEmpty else {
                    toast = Toast(message: "Everything here is already read", systemImage: "checkmark.circle")
                    return
                }
                toast = Toast(message: "Marked \(marked.count) as read", systemImage: "checkmark.circle",
                              actionTitle: "Undo") { model.setRead(marked, false) }
            }
            .disabled(all.isEmpty)
            if isLive {
                Divider()
                if model.isFollowing(current) {
                    Button("Unfollow \(current)", systemImage: "minus.circle") {
                        model.setFollowing(current, false)
                    }
                } else {
                    Button("Follow \(current)", systemImage: "plus.circle") {
                        model.setFollowing(current, true)
                    }
                }
            }
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isLive {
            ContentUnavailableView {
                Label("No \(current) stories right now", systemImage: TopicStyle.of(current).symbol)
            } description: {
                Text(model.feedStatus?.message
                     ?? "New stories show up here as they come in. Muted words and turned-off sources can hide some.")
            }
        } else if loadFailed {
            ContentUnavailableView("This brief couldn't be opened", systemImage: "calendar.badge.exclamationmark",
                                   description: Text("It may have been removed after 30 days."))
        } else {
            ContentUnavailableView("No \(current) stories that day", systemImage: TopicStyle.of(current).symbol)
        }
    }
}
