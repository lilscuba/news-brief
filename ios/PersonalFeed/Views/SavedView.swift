import SwiftUI

/// The Saved tab: stories kept for later, what was read recently, and past briefs. Everything here
/// lives on this phone, so it stays readable after a story leaves the 48-hour feed.
struct SavedView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    /// Rows shown before "See all".
    static let recentPreview = 5
    static let pastPreview = 7

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.savedPath) {
            let past = model.pastBriefEntries
            List {
                Section {
                    if model.saved.isEmpty {
                        Label {
                            Text("Swipe left on a story, or tap \(Image(systemName: "bookmark")) on its page, to keep it here for later.")
                        } icon: {
                            Image(systemName: "bookmark").foregroundStyle(.tint)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.saved) { item in
                            StoryLink(story: item.story, showsTopic: true, trailingSwipe: .removeSaved)
                        }
                    }
                } header: {
                    SavedHeader(title: "Saved stories", count: model.saved.count)
                }

                if !model.recent.isEmpty {
                    Section {
                        ForEach(model.recent.prefix(Self.recentPreview)) { item in
                            StoryLink(story: item.story, showsTopic: true)
                        }
                        if model.recent.count > Self.recentPreview {
                            NavigationLink(value: SavedPage.recentlyRead) {
                                Text("See all \(model.recent.count) recently read")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    } header: {
                        SavedHeader(title: "Recently read")
                    }
                }

                Section {
                    if past.isEmpty {
                        Text("Each day's brief is kept here for 30 days.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(past.prefix(Self.pastPreview)) { entry in
                            NavigationLink(value: PastBriefDestination(date: entry.date)) {
                                PastBriefRow(entry: entry)
                            }
                        }
                        if past.count > Self.pastPreview {
                            NavigationLink(value: SavedPage.pastBriefs) {
                                Text("See all \(past.count) past briefs")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                } header: {
                    SavedHeader(title: "Past briefs")
                }
            }
            .listStyle(.insetGrouped)
            .minuteClock()
            .navigationTitle("Saved")
            .toolbar {
                if !model.recent.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Clear Recently Read", systemImage: "trash", role: .destructive) {
                                confirmClear = true
                            }
                        } label: {
                            Label("Options", systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
            .confirmationDialog("Clear recently read?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Recently Read", role: .destructive) { model.clearRecent() }
            } message: {
                Text("Stories stay marked as read. Saved stories aren't affected.")
            }
            // Registered once, here at the stack root; every push is a value.
            .navigationDestination(for: Story.self) { StoryDetailView(story: $0) }
            .navigationDestination(for: PastStoryDestination.self) { StoryDetailView(story: $0.story, day: $0.day) }
            .navigationDestination(for: TopicDestination.self) { TopicPageView(destination: $0) }
            .navigationDestination(for: PastBriefDestination.self) { PastBriefView(date: $0.date) }
            .navigationDestination(for: SavedPage.self) { page in
                switch page {
                case .recentlyRead: RecentlyReadView()
                case .pastBriefs: PastBriefsView()
                }
            }
        }
    }
}

/// Full lists behind the Saved tab's "See all" rows.
enum SavedPage: String, Hashable, Codable {
    case recentlyRead, pastBriefs
}

/// A section title in the same weight as Today's topic headers.
private struct SavedHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.primary)
            Spacer()
            if let count, count > 0 {
                Text("\(count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct RecentlyReadView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.recent) { item in
                StoryLink(story: item.story, showsTopic: true)
            }
        }
        .listStyle(.insetGrouped)
        .minuteClock()
        .overlay {
            if model.recent.isEmpty {
                ContentUnavailableView("Nothing read yet", systemImage: "book",
                                       description: Text("Stories you open show up here."))
            }
        }
        .navigationTitle("Recently Read")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PastBriefsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.pastBriefEntries) { entry in
            NavigationLink(value: PastBriefDestination(date: entry.date)) {
                PastBriefRow(entry: entry)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Past Briefs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One day: the date, its lead story and how many stories it had.
struct PastBriefRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.displayDate)
                .font(.headline)
            if let top = entry.topTitle {
                Text(top)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("\(entry.storyCount) \(entry.storyCount == 1 ? "story" : "stories")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A past day's brief, loaded from disk when opened, in the same layout as Today.
struct PastBriefView: View {
    @Environment(AppModel.self) private var model
    let date: String
    @State private var brief: Brief?
    @State private var loaded = false

    var body: some View {
        Group {
            if let brief {
                BriefView(brief: brief)
            } else if loaded {
                ContentUnavailableView("This brief couldn't be opened", systemImage: "calendar.badge.exclamationmark",
                                       description: Text("It may have been removed after 30 days."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(brief?.displayDate ?? HistoryEntry.displayDate(date))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: date) {
            brief = await model.loadBrief(day: date)
            loaded = true
        }
    }
}

private extension HistoryEntry {
    static func displayDate(_ date: String) -> String {
        guard let day = Brief.dayFormatter.date(from: date) else { return date }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}
