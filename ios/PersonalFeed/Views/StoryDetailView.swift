import SwiftUI
import UIKit

/// A story's page: what happened, who reported it and when, the article, every outlet's take, and
/// where to go next (the same event in other topics, more from this topic). Opening it marks the
/// story read and lists it under Recently read.
struct StoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let story: Story
    /// The past brief the story was opened from: "More in" and "See all" stay on that day.
    var day: String? = nil
    @AppStorage(ArticleLink.readerModeKey) private var readerMode = true
    @AppStorage(StorySort.storageKey) private var sort: StorySort = .hot
    @State private var showsAllCoverage = false
    /// Once per visit: coming back from a related story mustn't undo "Mark as Unread".
    @State private var notedOpen = false

    var body: some View {
        let coverage = Coverage(story)
        let related = model.relatedStories(to: story)
        let topicStories = sort.apply(model.stories(inTopic: story.category, day: day))
        let more = StoryPage.moreInTopic(after: story, in: topicStories,
                                         excluding: Set(related.map(\.id)), isRead: model.isRead)
        List {
            Section {
                header(coverage)
            }

            if coverage.isShown {
                Section {
                    ForEach(coverage.visibleEntries(showingAll: showsAllCoverage)) { entry in
                        CoverageRow(story: story, entry: entry, readerMode: readerMode)
                            // Same outlet, one block: no line between its headlines.
                            .listRowSeparator(entry.startsOutlet ? .automatic : .hidden, edges: .top)
                    }
                    if !showsAllCoverage && coverage.isCollapsed {
                        Button {
                            withAnimation { showsAllCoverage = true }
                        } label: {
                            Text(coverage.showAllTitle)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                } header: {
                    Text(coverage.title)
                }
            }

            if !related.isEmpty {
                Section("More on this story") {
                    ForEach(related) { StoryLink(story: $0, showsTopic: true) }
                }
            }

            if topicStories.contains(where: { $0.id != story.id }) {
                Section("More in \(story.category)") {
                    ForEach(more) { StoryLink(story: $0, hidesDealLabel: story.category == "Deals", day: day) }
                    NavigationLink(value: TopicDestination(name: story.category, day: day)) {
                        Text("See all \(topicStories.count) in \(story.category)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .minuteClock()
        .navigationTitle(story.category)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear {
            guard !notedOpen else { return }
            notedOpen = true
            model.noteOpened(story)  // read, and listed under Recently read
        }
    }

    // MARK: Header

    private func header(_ coverage: Coverage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StoryTags(story: story)
            Text(story.title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            // Absolute times: they don't tick while you read, and "first reported" can't be
            // mistaken for the latest coverage.
            Text(StoryPage.byline(story, outletCount: coverage.outletCount, now: .now))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if story.hasUsefulSummary {
                Text(story.summary)
                    .font(.body)
                    .textSelection(.enabled)
                if story.aiSummary == true {
                    Label("Summarized by AI from the outlets' headlines and snippets", systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(StoryPage.noPreview(story))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // With several outlets, each headline's translation is noted under Coverage.
            if !coverage.isShown, let note = StoryPage.translationNote(story.sources.first) {
                Label(note, systemImage: "globe")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let lead = story.sources.first {
                readButton(lead.url)
                    .padding(.top, 4)
                if readerMode {
                    Text("Opens in Reader view when the page supports it")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// Tap opens the article as the Reader setting says; touch and hold for the alternatives.
    private func readButton(_ url: URL) -> some View {
        Menu {
            Button(readerMode ? "Open without Reader" : "Open in Reader View",
                   systemImage: readerMode ? "doc.richtext" : "doc.plaintext") {
                model.openArticle(story, reader: !readerMode)
            }
            Button("Open in Safari", systemImage: "safari") {
                model.noteOpened(story)
                openURL(url)
            }
            Divider()
            Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = url }
            ShareLink(item: url, subject: Text(story.title), message: Text(story.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } label: {
            // Text, not a Label: a Menu's label drops the icon but kept its space, which pushed
            // the first line off centre when the title wrapped.
            Text(StoryPage.readTitle(story))
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } primaryAction: {
            model.openArticle(story)
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Opens the article. Touch and hold for other ways to open it.")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        let saved = model.isSaved(story)
        let read = model.isRead(story)
        let url = story.sources.first?.url
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.toggleSaved(story)
            } label: {
                Label(saved ? "Remove from Saved" : "Save for Later", systemImage: saved ? "bookmark.fill" : "bookmark")
            }
            .sensoryFeedback(.selection, trigger: saved)
            if let url {
                ShareLink(item: url, subject: Text(story.title), message: Text(story.title))
            }
            Menu {
                Button(read ? "Mark as Unread" : "Mark as Read",
                       systemImage: read ? "envelope.badge" : "envelope.open") {
                    model.setRead(story, !read)
                }
                if let url {
                    Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = url }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Header pieces

/// The topic, a notable reliability label and "Opinion", as small capsules. Wraps onto separate
/// lines when they don't fit (large text).
private struct StoryTags: View {
    let story: Story

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { tags(wrap: false) }
            // Stacked, a pill may still be wider than the row at the largest sizes: it wraps.
            VStack(alignment: .leading, spacing: 6) { tags(wrap: true) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func tags(wrap: Bool) -> some View {
        let style = TopicStyle.of(story.category)
        TagPill(text: story.category, systemImage: style.symbol, tint: style.color, wraps: wrap)
        if let label = story.notableReliability {
            TagPill(text: label.displayName, systemImage: label.systemImage, tint: label.tint, wraps: wrap)
                .accessibilityLabel(label.spokenText)
        }
        if story.isOpinion {
            TagPill(text: "Opinion", systemImage: "quote.bubble.fill", tint: .gray, wraps: wrap)
        }
    }
}

/// A capsule with a tinted icon and words, so it never relies on colour alone. An HStack rather
/// than a Label: inside the list row's ViewThatFits a Label dropped its title.
private struct TagPill: View {
    let text: String
    let systemImage: String
    let tint: Color
    /// Wrap the text instead of insisting on one line (the stacked layout at large sizes).
    var wraps = false
    @ScaledMetric(relativeTo: .caption) private var hPadding: CGFloat = 8
    @ScaledMetric(relativeTo: .caption) private var vPadding: CGFloat = 3

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(Color.primary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: wraps ? 10 : 100, style: .continuous))
        .fixedSize(horizontal: !wraps, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Coverage

/// One outlet's headline under "Coverage from N outlets". Opens that outlet's article.
private struct CoverageRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.listClock) private var clock
    let story: Story
    let entry: Coverage.Entry
    let readerMode: Bool

    var body: some View {
        let source = entry.source
        let now = clock ?? .now
        Button {
            model.openArticle(story, source: source)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                caption(now: now)
                    .font(entry.startsOutlet ? .subheadline : .caption)
                    .foregroundStyle(.secondary)
                Text(source.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let note = StoryPage.translationNote(source) {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(.primary)
        .contextMenu { menu(source) }
        .accessibilityLabel("\(source.shortOutlet): \(source.title)")
        .accessibilityValue(StoryPage.spokenCoverage(entry, now: now))
        .accessibilityAction(named: readerMode ? "Open without Reader" : "Open in Reader View") {
            model.openArticle(story, source: source, reader: !readerMode)
        }
        .accessibilityAction(named: "Copy link") { UIPasteboard.general.url = source.url }
    }

    /// "The Guardian ✓ · 2h ago · First report" on an outlet's first headline, just the age on
    /// its others.
    private func caption(now: Date) -> Text {
        let source = entry.source
        var line: Text
        if entry.startsOutlet {
            let name = Text(source.shortOutlet).fontWeight(.semibold).foregroundStyle(.primary)
            line = source.official
                ? Text("\(name) \(Text(Image(systemName: "checkmark.seal.fill")).foregroundStyle(.blue))")
                : name
            if let published = source.published {
                line = Text("\(line)\u{00A0}· \(RelativeAge.short(published, now: now))")
            }
        } else {
            line = Text(source.published.map { RelativeAge.short($0, now: now) } ?? "")
        }
        if entry.isFirst {
            line = Text("\(line)\u{00A0}· \(Text("First report").fontWeight(.semibold))")
        }
        return line
    }

    @ViewBuilder
    private func menu(_ source: Source) -> some View {
        Button("Read Article", systemImage: "doc.plaintext") { model.openArticle(story, source: source) }
        Button(readerMode ? "Open without Reader" : "Open in Reader View",
               systemImage: readerMode ? "doc.richtext" : "doc.plaintext") {
            model.openArticle(story, source: source, reader: !readerMode)
        }
        Button("Open in Safari", systemImage: "safari") {
            model.noteOpened(story)
            openURL(source.url)
        }
        Divider()
        Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = source.url }
        ShareLink(item: source.url, subject: Text(source.title), message: Text(source.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

/// Every outlet's headline for a story, one block per outlet (an outlet that ran it twice is
/// listed once), the most recent first, with the earliest report marked.
struct Coverage: Equatable {
    struct Entry: Identifiable, Equatable {
        let source: Source
        /// Position in `story.sources`; two feeds can carry the same link.
        let index: Int
        /// The outlet's first headline here, which names the outlet.
        let startsOutlet: Bool
        /// The earliest report of the story, when that's known and the outlets differ.
        let isFirst: Bool
        var id: Int { index }
    }

    /// Distinct outlets, in the order listed.
    let outlets: [String]
    let entries: [Entry]

    var outletCount: Int { outlets.count }
    /// One source repeats the headline, so the section only shows with more.
    var isShown: Bool { entries.count > 1 }

    var title: String {
        outletCount > 1 ? "Coverage from \(outletCount) outlets"
                        : "\(entries.count) headlines from \(outlets.first ?? "one outlet")"
    }

    /// A big story can have 17 outlets; the newest few say enough until the reader asks for more
    /// (the byline already names who reported it first).
    static let collapsedCount = 5
    var isCollapsed: Bool { entries.count > Self.collapsedCount + 1 }

    func visibleEntries(showingAll: Bool) -> [Entry] {
        showingAll || !isCollapsed ? entries : Array(entries.prefix(Self.collapsedCount))
    }

    var showAllTitle: String {
        entries.count == outletCount ? "Show all \(outletCount) outlets" : "Show all \(entries.count) headlines"
    }

    init(_ story: Story) {
        var order: [String] = []
        var groups: [String: [(source: Source, index: Int)]] = [:]
        for (index, source) in story.sources.enumerated() {
            let name = source.shortOutlet
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append((source, index))
        }
        // Newest first; undated sources (briefs saved by older builds) keep the feed's order.
        func newer(_ a: (date: Date?, index: Int), _ b: (date: Date?, index: Int)) -> Bool {
            switch (a.date, b.date) {
            case let (x?, y?) where x != y: x > y
            case (.some, nil): true
            case (nil, .some): false
            default: a.index < b.index
            }
        }
        let sortedGroups = order.map { name in
            (groups[name] ?? []).sorted { newer(($0.source.published, $0.index), ($1.source.published, $1.index)) }
        }.sorted { a, b in
            newer((a.first?.source.published, a.first?.index ?? 0), (b.first?.source.published, b.first?.index ?? 0))
        }

        // Only worth saying when several outlets reported it at different times.
        var firstIndex: Int?
        let dated = story.sources.enumerated().compactMap { i, s in s.published.map { (date: $0, index: i) } }
        if order.count > 1, let earliest = dated.min(by: { $0.date < $1.date }),
           let latest = dated.map(\.date).max(), latest > earliest.date {
            firstIndex = earliest.index
        }

        outlets = sortedGroups.compactMap { $0.first?.source.shortOutlet }
        entries = sortedGroups.flatMap { group in
            group.enumerated().map { position, item in
                Entry(source: item.source, index: item.index, startsOutlet: position == 0,
                      isFirst: item.index == firstIndex)
            }
        }
    }
}

// MARK: - Wording

/// The story page's text, kept apart from the views so it can be tested.
enum StoryPage {
    /// "Read at The Guardian". The link goes to the publisher, so "Bloomberg via Techmeme" reads
    /// "Read at Bloomberg".
    static func readTitle(_ story: Story) -> String {
        let outlet = StoryCaption.rowOutlet(story.leadOutlet)
        return outlet.isEmpty ? "Read Article" : "Read at \(outlet)"
    }

    /// "The Guardian · Mon 6:01 AM" for one outlet; with several, when it broke and by whom, when
    /// coverage last grew, and how many outlets: "First reported 11:49 PM by CS Monitor · Updated
    /// 6:01 AM · 18 outlets".
    static func byline(_ story: Story, outletCount: Int, now: Date, calendar: Calendar = .current) -> String {
        let updated = time(story.published, now: now, calendar: calendar)
        guard outletCount > 1 else {
            return [story.leadOutlet, updated].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let dated = story.sources.compactMap { s in s.published.map { (source: s, date: $0) } }
        if let first = dated.min(by: { $0.date < $1.date }), story.published.timeIntervalSince(first.date) >= 60 {
            return "First reported \(time(first.date, now: now, calendar: calendar)) by \(first.source.shortOutlet)"
                + " · Updated \(updated) · \(outletCount) outlets"
        }
        return [story.leadOutlet, updated, "\(outletCount) outlets"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "6:01 AM" today, "Mon 6:01 AM" earlier this week, "Oct 2, 6:01 AM" before that.
    static func time(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(style) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if (1..<6).contains(days) { return date.formatted(style.weekday(.abbreviated)) }
        return date.formatted(style.month(.abbreviated).day())
    }

    /// Shown instead of an empty or headline-repeating summary, so the gap isn't a mystery.
    static func noPreview(_ story: Story) -> String {
        story.leadOutlet.isEmpty
            ? "No preview for this story. Open the article to read it."
            : "No preview from \(story.leadOutlet). Open the article to read it."
    }

    /// "Translated from Japanese: <original headline>".
    static func translationNote(_ source: Source?, locale: Locale = .current) -> String? {
        guard let source, let code = source.translatedFrom else { return nil }
        let language = locale.localizedString(forLanguageCode: code) ?? code
        guard let original = source.originalTitle, !original.isEmpty else { return "Translated from \(language)" }
        return "Translated from \(language): \(original)"
    }

    /// The next unread stories of the topic after this one (wrapping round to the top), leaving
    /// out ones already shown under "More on this story".
    static func moreInTopic(after story: Story, in topic: [Story], excluding: Set<String>,
                            isRead: (Story) -> Bool, limit: Int = 3) -> [Story] {
        let start = topic.firstIndex { $0.id == story.id }.map { $0 + 1 } ?? 0
        let ordered = topic[start...] + topic[..<start]
        return Array(ordered.filter { $0.id != story.id && !excluding.contains($0.id) && !isRead($0) }.prefix(limit))
    }

    /// VoiceOver value of a coverage row: "2 hours ago, first report, official, translated".
    static func spokenCoverage(_ entry: Coverage.Entry, now: Date) -> String {
        var parts: [String] = []
        if let published = entry.source.published { parts.append(RelativeAge.spoken(published, now: now)) }
        if entry.isFirst { parts.append("first report") }
        if entry.source.official { parts.append("official source") }
        if entry.source.translatedFrom != nil { parts.append("translated") }
        return parts.joined(separator: ", ")
    }
}
