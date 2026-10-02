import SwiftUI

/// One day's brief as a single scrolling feed: the headline, Top stories, then a short preview of
/// every followed topic with a "See all" page. A "Topics" menu in the navigation bar opens one.
struct BriefView: View {
    let brief: Brief
    /// e.g. "Offline: showing the last update."
    let status: String?
    @AppStorage(StorySort.storageKey) private var sort: StorySort = .hot

    /// Stories shown per topic in the feed before "See all".
    static let previewCount = 3

    init(brief: Brief, status: String? = nil) {
        self.brief = brief
        self.status = status
    }

    private var topics: [BriefSection] { brief.sections.filter { !$0.stories.isEmpty } }

    var body: some View {
        List {
            headerSection

            if topics.isEmpty && brief.top.isEmpty {
                ContentUnavailableView("Nothing new yet",
                                       systemImage: "tray",
                                       description: Text("New stories show up here as they come in."))
                    .listRowBackground(Color.clear)
            }

            if !brief.top.isEmpty {
                Section {
                    ForEach(sort.apply(brief.top)) { story in
                        NavigationLink(value: story) { StoryRow(story: story) }
                    }
                } header: {
                    TopicHeader(name: Self.topTitle, count: nil, showsChevron: false)
                }
            }

            ForEach(topics) { topic in
                let destination = TopicDestination(name: topic.name, stories: topic.stories)
                Section {
                    ForEach(sort.apply(topic.stories).prefix(Self.previewCount)) { story in
                        NavigationLink(value: story) { StoryRow(story: story) }
                    }
                    if topic.stories.count > Self.previewCount {
                        NavigationLink(value: destination) {
                            Text("See all \(topic.stories.count) in \(topic.name)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                } header: {
                    NavigationLink(value: destination) {
                        TopicHeader(name: topic.name, count: topic.stories.count, showsChevron: true)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section { footer }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: TopicDestination.self) { TopicListView(topic: $0) }
        .toolbar {
            if !topics.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // A value link, like every other push here. A separate bound
                        // navigationDestination(item:) on the same stack left the article links on
                        // that topic page highlighted but not opening until the next tap.
                        ForEach(topics) { topic in
                            NavigationLink(value: TopicDestination(name: topic.name, stories: topic.stories)) {
                                Label("\(topic.name) · \(topic.stories.count)",
                                      systemImage: TopicStyle.of(topic.name).symbol)
                            }
                        }
                    } label: {
                        Label("Topics", systemImage: "list.bullet")
                    }
                }
            }
        }
    }

    static let topTitle = "Top stories"

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(brief.displayDate.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tint)
                Text(brief.headline)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    Label(status, systemImage: "wifi.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                SortPicker()
                    .padding(.top, 4)
            }
            .padding(.vertical, 6)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Updated \(brief.generatedAt.formatted(.relative(presentation: .named))). Headlines and snippets come straight from each source.")
            if !brief.sourceProblems.isEmpty {
                Label("Not responding right now: \(brief.sourceProblems.joined(separator: ", "))",
                      systemImage: "exclamationmark.circle")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Where "See all" goes: every story of one topic.
struct TopicDestination: Hashable {
    let name: String
    let stories: [Story]
}

struct TopicListView: View {
    let topic: TopicDestination
    @AppStorage(StorySort.storageKey) private var sort: StorySort = .hot

    var body: some View {
        List {
            Section {
                SortPicker()
            } header: {
                Text("\(topic.stories.count) \(topic.stories.count == 1 ? "story" : "stories")")
            }

            Section {
                ForEach(sort.apply(topic.stories)) { story in
                    NavigationLink(value: story) { StoryRow(story: story) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(topic.name)
        .navigationBarTitleDisplayMode(.large)
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

/// Section header: coloured icon, topic name, story count and a chevron when it opens a page.
struct TopicHeader: View {
    let name: String
    let count: Int?
    let showsChevron: Bool

    var body: some View {
        let style = TopicStyle.of(name)
        HStack(spacing: 10) {
            Image(systemName: style.symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(style.color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(name)
                .font(.title3.weight(.bold))
                // Color.primary, not .primary: list headers pass down a secondary style that the
                // hierarchical .primary would inherit.
                .foregroundStyle(Color.primary)
            Spacer(minLength: 8)
            if let count {
                Text("\(count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .textCase(nil)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct StoryRow: View {
    @Environment(AppModel.self) private var store
    @AppStorage(StorySort.storageKey) private var sort: StorySort = .hot
    let story: Story

    var body: some View {
        let read = store.isRead(story)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let label = story.label { LabelBadge(label: label) }
                ImportanceDots(level: story.importance)
                Text(story.category)
                Text("·")
                Text(story.outletCount == 1 ? "1 outlet" : "\(story.outletCount) outlets")
                if story.isTranslated {
                    Image(systemName: "globe")
                        .accessibilityLabel("Translated")
                }
                if sort == .latest {
                    Text("·")
                    Text(story.published.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(story.title)
                .font(.headline)
                .foregroundStyle(read ? .secondary : .primary)
            Text(story.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }
}

/// Reliability label, so a rumor never reads like a confirmed announcement.
struct LabelBadge: View {
    let label: String

    private var color: Color {
        switch label {
        case "CONFIRMED": .green
        case "RUMOR-CREDIBLE": .orange
        case "RUMOR-UNVERIFIED": .red
        case "DEAL": .purple
        default: .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1))
    }
}

struct ImportanceDots: View {
    let level: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Circle()
                    .fill(i <= level ? Color.orange : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Importance \(level) of 5")
    }
}
