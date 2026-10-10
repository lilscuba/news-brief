import SwiftUI
import UIKit

/// One story in a list: a new/read marker, one caption line (label, outlet, age, topic), the
/// headline and, when it adds something, a two-line summary. Read and new state come from the
/// caller so a long list reads the model once per row, not once per piece of the row.
struct StoryRow: View {
    let story: Story
    var isRead = false
    var isNew = false
    var isSaved = false
    /// Top stories, search and the new-stories list mix topics; a topic's own rows don't repeat it.
    var showsTopic = false
    /// Inside Deals every row is a deal, so the badge says nothing there.
    var hidesDealLabel = false

    @Environment(\.listClock) private var clock
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var markerSize: CGFloat = 9

    var body: some View {
        let now = clock ?? .now
        HStack(alignment: .storyTitle, spacing: 8) {
            marker
                .frame(width: markerSize + 2)
            VStack(alignment: .leading, spacing: 4) {
                StoryCaption.text(story, showsTopic: showsTopic, hidesDealLabel: hidesDealLabel,
                                  isSaved: isSaved, now: now)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(story.title)
                    .font(isRead ? .headline.weight(.regular) : .headline)
                    .foregroundStyle(isRead ? .secondary : .primary)
                    .alignmentGuide(.storyTitle) { $0[.firstTextBaseline] }
                // At accessibility sizes two summary lines would push every headline off screen.
                if story.hasUsefulSummary && !typeSize.isAccessibilitySize {
                    Text(story.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StoryCaption.spokenTitle(story))
        .accessibilityValue(StoryCaption.spokenDetails(story, isRead: isRead, isNew: isNew, isSaved: isSaved,
                                                       showsTopic: showsTopic, now: now))
        .accessibilityCustomContent(AccessibilityCustomContentKey("Summary"),
                                    story.hasUsefulSummary ? Text(story.summary) : nil)
    }

    /// A tinted dot for new, a check for read, nothing for the rest (most rows), so the eye goes
    /// to what changed. Shape, not just colour, tells them apart.
    @ViewBuilder
    private var marker: some View {
        if isNew {
            Circle()
                .fill(Color.accentColor)
                .frame(width: markerSize, height: markerSize)
                // Sits on the headline's first line, like Mail's unread dot.
                .alignmentGuide(.storyTitle) { $0[.bottom] }
        } else if isRead {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        } else {
            Color.clear.frame(width: markerSize, height: markerSize)
                .alignmentGuide(.storyTitle) { $0[.bottom] }
        }
    }
}

extension VerticalAlignment {
    private enum StoryTitle: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[.firstTextBaseline] }
    }

    /// The first line of a row's headline, so the new/read marker lines up with it.
    static let storyTitle = VerticalAlignment(StoryTitle.self)
}

/// The caption and VoiceOver text for a story, shared by rows and previews.
enum StoryCaption {
    /// One Text, so at large sizes it wraps as a sentence instead of each piece truncating alone:
    /// "⚠ Credible rumor · The Verge +3 · 2h ago · Tech".
    static func text(_ story: Story, showsTopic: Bool, hidesDealLabel: Bool = false, isSaved: Bool = false,
                     now: Date) -> Text {
        var parts: [Text] = []
        if let label = story.notableReliability, !(hidesDealLabel && label == .deal) {
            let icon = Text(Image(systemName: label.systemImage)).foregroundStyle(label.tint)
            parts.append(Text("\(icon) \(label.displayName)").fontWeight(.semibold).foregroundStyle(.primary))
        }
        if story.isOpinion {
            parts.append(Text("Opinion").fontWeight(.semibold).foregroundStyle(.primary))
        }
        if let outlet = outletText(story) {
            parts.append(story.isTranslated
                         ? Text("\(outlet) \(Image(systemName: "globe"))")
                         : Text(outlet))
        }
        parts.append(Text(RelativeAge.short(story.published, now: now)))
        if showsTopic { parts.append(Text(story.category)) }
        guard var line = parts.first else { return Text("") }
        // No-break spaces keep each "·" and the bookmark with the word before them, so a wrapped
        // line never starts with a separator or a lone icon.
        for part in parts.dropFirst() { line = Text("\(line)\u{00A0}· \(part)") }
        if isSaved { line = Text("\(line)\u{00A0}\u{00A0}\(Image(systemName: "bookmark.fill"))") }
        return line
    }

    /// "The Verge +3": the headline's outlet and how many others covered it.
    static func outletText(_ story: Story) -> String? {
        let lead = rowOutlet(story.leadOutlet)
        guard !lead.isEmpty else { return story.outletCount > 1 ? "\(story.outletCount) outlets" : nil }
        return story.outletCount > 1 ? "\(lead) +\(story.outletCount - 1)" : lead
    }

    /// "Bloomberg via Techmeme" → "Bloomberg": the publisher is what a row needs; the story page
    /// keeps the full name.
    static func rowOutlet(_ outlet: String) -> String {
        guard let via = outlet.range(of: " via ", options: .backwards), via.lowerBound > outlet.startIndex else {
            return outlet
        }
        return String(outlet[..<via.lowerBound])
    }

    /// Headline first; a rumor, confirmation, deal or opinion is said before it so it's never
    /// heard as plain news.
    static func spokenTitle(_ story: Story) -> String {
        var kinds: [String] = []
        if let label = story.notableReliability { kinds.append(label.spokenText) }
        if story.isOpinion { kinds.append("Opinion") }
        return kinds.isEmpty ? story.title : "\(kinds.joined(separator: ", ")): \(story.title)"
    }

    /// "New, 2 hours ago, The Verge and 3 other outlets, Tech, translated, saved".
    static func spokenDetails(_ story: Story, isRead: Bool, isNew: Bool, isSaved: Bool, showsTopic: Bool,
                              now: Date) -> String {
        var parts: [String] = []
        if isNew { parts.append("New") } else if isRead { parts.append("Read") }
        parts.append(RelativeAge.spoken(story.published, now: now))
        let others = story.outletCount - 1
        let lead = rowOutlet(story.leadOutlet)
        if !lead.isEmpty {
            parts.append(others > 0 ? "\(lead) and \(others) other \(others == 1 ? "outlet" : "outlets")" : lead)
        }
        if showsTopic { parts.append(story.category) }
        if story.isTranslated { parts.append("translated") }
        if isSaved { parts.append("saved") }
        return parts.joined(separator: ", ")
    }
}

extension ReliabilityLabel {
    /// Colours the label's icon only; the words carry the meaning and stay readable.
    var tint: Color {
        switch self {
        case .confirmed: .green
        case .reported: .secondary
        case .credibleRumor: .orange
        case .unverifiedRumor: .red
        case .deal: .purple
        }
    }
}

/// Story ages: "2h ago" in rows, "2 hours ago" for VoiceOver. A time in the future (clock skew
/// between the phone and the feed) reads as just now.
enum RelativeAge {
    static func short(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Just now" }
        return shortFormatter.localizedString(for: date, relativeTo: now)
    }

    static func spoken(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        return spokenFormatter.localizedString(for: date, relativeTo: now)
    }

    // A formatter rather than Date.formatted(.relative): that one always measures from the real
    // clock, not from `now` (the list's minute tick).
    private static let shortFormatter = formatter(.abbreviated)
    private static let spokenFormatter = formatter(.full)

    private static func formatter(_ style: RelativeDateTimeFormatter.UnitsStyle) -> RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = style
        f.dateTimeStyle = .numeric
        return f
    }
}

// MARK: - A row in a list, with its actions

/// A story row that opens the story page, with swipe actions (read, save), a context menu with a
/// preview, and the same actions for VoiceOver.
struct StoryLink: View {
    @Environment(AppModel.self) private var model
    let story: Story
    var showsTopic = false
    var hidesDealLabel = false
    var trailingSwipe: TrailingSwipe = .save
    /// The past brief this row belongs to; nil for today's (or no particular day).
    var day: String? = nil

    enum TrailingSwipe {
        /// Save or unsave.
        case save
        /// In Saved: remove it from the list.
        case removeSaved
    }

    var body: some View {
        let read = model.isRead(story)
        let saved = model.isSaved(story)
        // Every row in Saved is saved; the bookmark mark only says something elsewhere.
        let row = StoryRow(story: story, isRead: read, isNew: model.isNew(story),
                           isSaved: saved && trailingSwipe != .removeSaved,
                           showsTopic: showsTopic, hidesDealLabel: hidesDealLabel)
        Group {
            if let day {
                NavigationLink(value: PastStoryDestination(story: story, day: day)) { row }
            } else {
                NavigationLink(value: story) { row }
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                model.setRead(story, !read)
            } label: {
                Label(read ? "Unread" : "Read", systemImage: read ? "envelope.badge" : "envelope.open")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            switch trailingSwipe {
            case .save:
                Button {
                    model.setSaved(story, !saved)
                } label: {
                    Label(saved ? "Unsave" : "Save", systemImage: saved ? "bookmark.slash" : "bookmark")
                }
                .tint(.orange)
            case .removeSaved:
                Button(role: .destructive) {
                    model.setSaved(story, false)
                } label: {
                    Label("Remove", systemImage: "bookmark.slash")
                }
            }
        }
        .contextMenu {
            StoryMenuItems(story: story, isRead: read, isSaved: saved)
        } preview: {
            StoryPreviewCard(story: story)
        }
        .accessibilityAction(named: "Read article") { model.openArticle(story) }
    }
}

/// The long-press menu of a story row.
struct StoryMenuItems: View {
    @Environment(AppModel.self) private var model
    let story: Story
    let isRead: Bool
    let isSaved: Bool

    var body: some View {
        if let url = story.sources.first?.url {
            Button("Read article", systemImage: "doc.plaintext") { model.openArticle(story) }
            Divider()
            Button(isSaved ? "Remove from Saved" : "Save for later",
                   systemImage: isSaved ? "bookmark.slash" : "bookmark") {
                model.setSaved(story, !isSaved)
            }
            Button(isRead ? "Mark as unread" : "Mark as read",
                   systemImage: isRead ? "envelope.badge" : "envelope.open") {
                model.setRead(story, !isRead)
            }
            Divider()
            ShareLink(item: url, subject: Text(story.title), message: Text(story.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button("Copy link", systemImage: "link") { UIPasteboard.general.url = url }
        }
    }
}

/// The card shown above the long-press menu: enough to decide whether to open the story.
struct StoryPreviewCard: View {
    let story: Story

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StoryCaption.text(story, showsTopic: true, now: .now)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(story.title)
                .font(.title3.weight(.semibold))
            if story.hasUsefulSummary {
                Text(story.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            if story.outlets.count > 1 {
                Text("Coverage: \(story.outlets.prefix(6).joined(separator: ", "))\(story.outlets.count > 6 ? "…" : "")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

// MARK: - Shared pieces

/// Reliability label as a small capsule: icon and words, so it never relies on colour alone.
/// Rows show the label inside their caption; this badge is for the story page.
struct LabelBadge: View {
    let reliability: ReliabilityLabel?
    let raw: String
    @ScaledMetric(relativeTo: .caption2) private var hPadding: CGFloat = 6
    @ScaledMetric(relativeTo: .caption2) private var vPadding: CGFloat = 2

    init(_ reliability: ReliabilityLabel) {
        self.reliability = reliability
        raw = reliability.rawValue
    }

    /// The pipeline's raw label, e.g. "RUMOR-CREDIBLE".
    init(label: String) {
        reliability = ReliabilityLabel(rawValue: label)
        raw = label
    }

    var body: some View {
        let tint = reliability?.tint ?? .secondary
        Label {
            Text(reliability?.displayName ?? raw.capitalized)
        } icon: {
            Image(systemName: reliability?.systemImage ?? "tag").foregroundStyle(tint)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.primary)
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .background(tint.opacity(0.16), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reliability?.spokenText ?? raw.capitalized)
    }
}

// MARK: - Ages that keep up

private struct ListClockKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// The current minute, for story ages. Set once per list by `MinuteClock` so ages don't freeze
    /// while the app stays open, without a timer in every row.
    var listClock: Date? {
        get { self[ListClockKey.self] }
        set { self[ListClockKey.self] = newValue }
    }
}

struct MinuteClock: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.everyMinute) { context in
            content.environment(\.listClock, context.date)
        }
    }
}

extension View {
    /// Keeps story ages in this list current, minute by minute.
    func minuteClock() -> some View { modifier(MinuteClock()) }
}
