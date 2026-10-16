import SwiftUI

/// Results for Today's search field: "My topics" searches the brief, "All topics" every topic in
/// the feed. Headline matches first, then the rest in hot order (StorySearch).
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(RecentSearches.storageKey) private var recentSearches = ""
    @State private var results: [Story] = []
    /// The query the results belong to; nil until the first search has run.
    @State private var resultsQuery: String?

    private struct Key: Equatable {
        let query: String
        let scope: SearchScope
        let feed: Date?
        let settings: UserSettings.BriefKey
    }

    var body: some View {
        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        List {
            if !results.isEmpty {
                Section {
                    ForEach(results) { story in
                        StoryLink(story: story, showsTopic: true)
                    }
                } header: {
                    Text("\(results.count) \(results.count == 1 ? "story" : "stories")")
                }
            }
        }
        .listStyle(.insetGrouped)
        .minuteClock()
        .overlay {
            if results.isEmpty, resultsQuery == query {
                ContentUnavailableView {
                    Label("No results for “\(query)”", systemImage: "magnifyingglass")
                } description: {
                    Text(model.searchScope == .mine
                         ? "Nothing in your topics matches. Try All topics, or fewer words."
                         : "Check the spelling or try fewer words.")
                } actions: {
                    if model.searchScope == .mine {
                        Button("Search All Topics") { model.searchScope = .all }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        // Waits for a pause in typing, and runs again when the brief changes underneath.
        .task(id: Key(query: query, scope: model.searchScope, feed: model.feed?.generatedAt,
                      settings: model.settings.briefKey)) {
            if resultsQuery != nil { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            results = model.search(query, scope: model.searchScope)
            resultsQuery = query
        }
        // Submitting is recorded beside .searchable (TodayView); opening a result counts too.
        .onDisappear {
            let current = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !current.isEmpty && !results.isEmpty { remember(current) }
        }
    }

    private func remember(_ query: String) {
        recentSearches = RecentSearches.adding(query, to: recentSearches)
    }
}

/// Recent searches under the empty search field.
struct RecentSearchSuggestions: View {
    @Environment(AppModel.self) private var model
    @AppStorage(RecentSearches.storageKey) private var recentSearches = ""

    var body: some View {
        // Only before typing: suggestions would otherwise sit on top of the results.
        if model.searchQuery.isEmpty {
            let terms = RecentSearches.list(recentSearches)
            if !terms.isEmpty {
                Section("Recent searches") {
                    ForEach(terms, id: \.self) { term in
                        Label(term, systemImage: "clock.arrow.circlepath")
                            .searchCompletion(term)
                    }
                }
            }
        }
    }
}

/// The last few searches, newest first, kept in UserDefaults as one line each.
enum RecentSearches {
    static let storageKey = "recentSearches"
    static let limit = 8

    static func list(_ stored: String) -> [String] {
        stored.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Moves `query` to the front (case-insensitively unique) and keeps the newest `limit`.
    static func adding(_ query: String, to stored: String) -> String {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !term.isEmpty else { return stored }
        let rest = list(stored).filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        return ([term] + rest).prefix(limit).joined(separator: "\n")
    }
}
