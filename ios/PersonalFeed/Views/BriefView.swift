import SwiftUI

/// One day's brief: headline, then a Top list plus one tab per followed topic.
struct BriefView: View {
    let brief: Brief
    /// e.g. "Offline: showing the last update."
    let status: String?
    @State private var selection: String

    static let topTab = "Top"

    init(brief: Brief, status: String? = nil, initialTopic: String = BriefView.topTab) {
        self.brief = brief
        self.status = status
        _selection = State(initialValue: initialTopic)
    }

    private var topics: [Topic] {
        [Topic(name: Self.topTab, count: nil)]
            + brief.sections.map { Topic(name: $0.name, count: $0.stories.count) }
    }

    private var stories: [Story] {
        if selection == Self.topTab { return brief.top }
        return brief.sections.first { $0.name == selection }?.stories ?? []
    }

    var body: some View {
        List {
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
                }
                .padding(.vertical, 6)
            }

            Section {
                if stories.isEmpty {
                    ContentUnavailableView("Nothing in \(selection) yet",
                                           systemImage: "tray",
                                           description: Text("New stories show up here as they come in."))
                        .listRowBackground(Color.clear)
                }
                ForEach(stories) { story in
                    NavigationLink(value: story) {
                        StoryRow(story: story)
                    }
                }
            } header: {
                if selection != Self.topTab, !stories.isEmpty {
                    Text("\(stories.count) \(stories.count == 1 ? "story" : "stories")")
                }
            }

            Section {
                footer
            }
        }
        .listStyle(.insetGrouped)
        .animation(.snappy, value: selection)
        // The topic chips stay pinned under the navigation bar while the list scrolls.
        .safeAreaInset(edge: .top, spacing: 0) {
            TopicBar(topics: topics, selection: $selection)
        }
        .onChange(of: brief.date) { selection = Self.topTab }
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

struct Topic: Identifiable, Hashable {
    let name: String
    /// Number of stories, or nil for the Top tab.
    let count: Int?
    var id: String { name }
}

/// Topic chips in a horizontally scrolling row. A segmented control squeezed up to nine topics
/// into one line; chips keep each label readable at any Dynamic Type size and scroll to keep the
/// selected topic in view.
struct TopicBar: View {
    let topics: [Topic]
    @Binding var selection: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(topics) { topic in
                        chip(topic).id(topic.name)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, name in
                withAnimation(.snappy) { proxy.scrollTo(name, anchor: .center) }
            }
        }
        // Only behind the chips: the default would also fill the navigation bar's safe area and
        // blur the large title.
        .background(.bar, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Divider() }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func chip(_ topic: Topic) -> some View {
        let selected = topic.name == selection
        return Button {
            withAnimation(.snappy) { selection = topic.name }
        } label: {
            HStack(spacing: 6) {
                Text(topic.name)
                if let count = topic.count, count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? Color.accentColor : Color(.secondarySystemFill)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct StoryRow: View {
    @Environment(AppModel.self) private var store
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
