import SwiftUI

/// "14 new since 9:40 AM": the stories that arrived since the last visit, across topics. The list
/// is taken when the page opens, so reading a story marks it read without it disappearing.
struct NewStoriesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(StorySort.storageKey) private var sort: StorySort = .hot
    @State private var ids: [String]?
    @State private var since: Date?
    @State private var toast: Toast?

    var body: some View {
        let stories = sort.apply(snapshot)
        List {
            Section {
                SortPicker()
            } header: {
                if let since, !stories.isEmpty {
                    Text(Freshness.newSince(count: stories.count, since: since, now: .now))
                }
            }
            if !stories.isEmpty {
                Section {
                    ForEach(stories) { story in
                        StoryLink(story: story, showsTopic: true)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .minuteClock()
        .overlay {
            if ids != nil && stories.isEmpty {
                ContentUnavailableView("You're all caught up", systemImage: "checkmark.circle",
                                       description: Text("Stories that arrive after this visit show up here next time."))
            }
        }
        .navigationTitle("New Stories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mark All as Read", systemImage: "checkmark.circle") {
                    let marked = model.markRead(stories)
                    guard !marked.isEmpty else { return }
                    toast = Toast(message: "Marked \(marked.count) as read", systemImage: "checkmark.circle",
                                  actionTitle: "Undo") { model.setRead(marked, false) }
                }
                .disabled(stories.allSatisfy(model.isRead))
            }
        }
        .refreshable { @MainActor in
            let result = await Toast.pullToRefresh(model)
            // Keep what was listed and add anything that just arrived.
            let known = Set(ids ?? [])
            ids = (ids ?? []) + model.newStories.map(\.id).filter { !known.contains($0) }
            toast = result
        }
        .onAppear {
            if ids == nil {
                ids = model.newStories.map(\.id)
                since = model.previousVisitAt
            }
        }
        .toast($toast)
    }

    /// The listed stories as they are now in the brief (coverage may have grown); one that left
    /// the brief is dropped.
    private var snapshot: [Story] {
        guard let ids, let brief = model.brief else { return [] }
        let byID = Dictionary(brief.allStories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }
}
