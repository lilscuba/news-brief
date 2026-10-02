import SwiftUI

/// One day's brief: headline, then a segmented Top / AI / Tech / Gaming / Deals list.
struct BriefView: View {
    let brief: Brief
    /// e.g. "Offline: showing the last update."
    var status: String? = nil
    @State private var selection = BriefView.topTab

    static let topTab = "Top"

    private var tabs: [String] { [Self.topTab] + brief.sections.map(\.name) }

    private var stories: [Story] {
        if selection == Self.topTab { return brief.top }
        return brief.sections.first { $0.name == selection }?.stories ?? []
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(brief.displayDate.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(brief.headline)
                        .font(.title3.weight(.semibold))
                    if let status {
                        Label(status, systemImage: "wifi.slash")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                Picker("Section", selection: $selection) {
                    ForEach(tabs, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            }

            Section {
                if stories.isEmpty {
                    Text("Nothing here yet today.")
                        .foregroundStyle(.secondary)
                }
                ForEach(stories) { story in
                    NavigationLink(value: story) {
                        StoryRow(story: story)
                    }
                }
            }

            Section {
                footer
            }
        }
        .listStyle(.insetGrouped)
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
                    Label("Translated", systemImage: "globe")
                        .labelStyle(.titleAndIcon)
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
