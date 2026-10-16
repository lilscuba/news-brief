import SwiftUI

/// One day's brief as a single scrolling feed, like a Reddit front page: every followed topic
/// mixed together and ranked (top stories first), each story a card with its picture. The topic
/// chips, or the filter menu in the navigation bar, narrow the feed to one topic.
struct BriefView: View {
    let brief: Brief
    /// e.g. "Offline: showing the last update."
    let status: String?
    @AppStorage(StorySort.storageKey) private var sort: StorySort = .hot
    /// The topic the feed is narrowed to; nil shows every topic.
    @State private var topic: String?

    private static let headerID = "header"

    init(brief: Brief, status: String? = nil) {
        self.brief = brief
        self.status = status
    }

    var body: some View {
        let all = brief.stories
        let filters = TopicFilter.counts(in: all, order: brief.sections.map(\.name))
        // A topic that was since unfollowed, or that a past brief doesn't have, shows everything.
        let selected = topic.flatMap { name in filters.contains(where: { $0.name == name }) ? name : nil }
        let stories = sort.apply(selected.map { name in all.filter { $0.category == name } } ?? all)
        let topIDs = Set(brief.top.map(\.id))
        let selection = Binding(get: { selected }, set: { topic = $0 })

        ScrollViewReader { proxy in
            List {
                header
                    .id(Self.headerID)
                    .listRowSeparator(.hidden)

                if filters.count > 1 {
                    TopicChips(filters: filters, selection: selection)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 12, trailing: 0))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                }

                if stories.isEmpty {
                    ContentUnavailableView("Nothing new yet",
                                           systemImage: "tray",
                                           description: Text("New stories show up here as they come in."))
                        .listRowSeparator(.hidden)
                }

                ForEach(stories) { story in
                    FeedRow(story: story, isTop: topIDs.contains(story.id))
                }

                footer
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .onChange(of: topic) { proxy.scrollTo(Self.headerID, anchor: .top) }
            // Forget a topic once it has no stories, so it can't narrow the feed again on its own
            // when a later refresh brings one back.
            .onChange(of: selected) { _, now in if now == nil { topic = nil } }
            .onChange(of: sort) { proxy.scrollTo(Self.headerID, anchor: .top) }
            .sensoryFeedback(.selection, trigger: topic)
        }
        .toolbar {
            if filters.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    FilterMenu(filters: filters, selection: selection)
                }
            }
        }
    }

    private var header: some View {
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
        .padding(.vertical, 12)
    }
}

/// A story card that opens the story. The link is hidden so the card has no disclosure chevron;
/// a tap anywhere on the card still opens it.
private struct FeedRow: View {
    let story: Story
    let isTop: Bool

    var body: some View {
        ZStack {
            NavigationLink(value: story) { EmptyView() }
                .opacity(0)
            StoryCard(story: story, isTop: isTop)
        }
        .listRowInsets(EdgeInsets())
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .contextMenu {
            if let first = story.sources.first {
                ShareLink(item: first.url, subject: Text(story.title))
            }
        }
    }
}

/// The navigation bar's filter: pick a topic or the sort order from anywhere in the feed,
/// without scrolling back up to the chips.
private struct FilterMenu: View {
    let filters: [TopicFilter]
    @Binding var selection: String?
    @AppStorage(StorySort.storageKey) private var sort: StorySort = .hot

    var body: some View {
        Menu {
            Picker("Topic", selection: $selection) {
                Label("All topics", systemImage: "square.stack").tag(String?.none)
                ForEach(filters) { filter in
                    Label("\(filter.name) · \(filter.count)", systemImage: TopicStyle.of(filter.name).symbol)
                        .tag(String?.some(filter.name))
                }
            }
            Picker("Sort stories by", selection: $sort) {
                ForEach(StorySort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            Label("Filter", systemImage: selection == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

/// One story in the feed, laid out like a Reddit post: its topic, outlet and age, the headline,
/// the picture (or the snippet when there isn't one) and how widely it's covered.
struct StoryCard: View {
    @Environment(AppModel.self) private var store
    let story: Story
    var isTop = false

    var body: some View {
        let read = store.isRead(story)
        let style = TopicStyle.of(story.category)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: style.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(style.color.gradient, in: Circle())
                    .accessibilityHidden(true)
                Text(story.category)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.primary)
                    .fixedSize()
                if let outlet = story.sources.first?.outlet {
                    Text("·")
                    Text(outlet)
                        .lineLimit(1)
                }
                Text("·")
                Text(story.published.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                    .fixedSize()
                Spacer(minLength: 4)
                if let label = story.label {
                    LabelBadge(label: label)
                        .fixedSize()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(story.title)
                .font(.headline)
                .foregroundStyle(read ? .secondary : .primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let image = story.image {
                StoryImage(url: image, topic: story.category)
            } else if !story.summary.isEmpty {
                Text(story.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                if isTop {
                    Label("Top story", systemImage: "flame.fill")
                        .foregroundStyle(.orange)
                        .pill()
                }
                HStack(spacing: 6) {
                    ImportanceDots(level: story.importance)
                    Text(story.outletCount == 1 ? "1 outlet" : "\(story.outletCount) outlets")
                }
                .pill()
                if story.isTranslated {
                    Label("Translated", systemImage: "globe")
                        .pill()
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
