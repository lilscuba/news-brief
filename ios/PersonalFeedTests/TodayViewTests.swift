import XCTest
@testable import PersonalFeed

/// The pure pieces behind Today, topic pages, search and rows: what the freshness line says,
/// what a topic preview shows, row captions and VoiceOver text, recent searches.
final class TodayViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func source(_ outlet: String, _ id: String = UUID().uuidString) -> Source {
        Source(outlet: outlet, title: "t", url: URL(string: "https://example.com/\(id)")!, official: false)
    }

    // MARK: Freshness line

    func testFreshnessSaysWhenTheNewsWasUpdated() {
        let f = Freshness.live(generatedAt: now.addingTimeInterval(-12 * 60), checkedAt: now, status: nil,
                               isChecking: false, now: now)
        XCTAssertEqual(f.tone, .normal)
        XCTAssertEqual(f.text, "Updated 12 minutes ago")
        XCTAssertNil(f.systemImage)
    }

    func testFreshnessWarnsWhenTheServerIsBehind() {
        let f = Freshness.live(generatedAt: now.addingTimeInterval(-3 * 3600 - 100), checkedAt: now,
                               status: nil, isChecking: false, now: now)
        XCTAssertEqual(f.tone, .stale)
        XCTAssertEqual(f.systemImage, "clock.badge.exclamationmark")
        // Blames the late update, and says the phone did check.
        XCTAssertEqual(f.text, "News last updated 3 hours ago · checked just now")

        // Just under the threshold is still normal.
        let fresh = Freshness.live(generatedAt: now.addingTimeInterval(-Freshness.staleAfter + 60),
                                   checkedAt: now, status: nil, isChecking: false, now: now)
        XCTAssertEqual(fresh.tone, .normal)
    }

    func testFreshnessShowsCheckingThenProblems() {
        let generated = now.addingTimeInterval(-3600)
        let checking = Freshness.live(generatedAt: generated, checkedAt: nil, status: .offline,
                                      isChecking: true, now: now)
        XCTAssertEqual(checking.tone, .checking)
        XCTAssertEqual(checking.text, "Checking for news…")

        let offline = Freshness.live(generatedAt: generated, checkedAt: nil, status: .offline,
                                     isChecking: false, now: now)
        XCTAssertEqual(offline.tone, .problem)
        XCTAssertEqual(offline.systemImage, "wifi.slash")
        XCTAssertEqual(offline.text, "You're offline · showing news from 1 hour ago")

        let server = Freshness.live(generatedAt: generated, checkedAt: nil, status: .server(503),
                                    isChecking: false, now: now)
        XCTAssertEqual(server.tone, .problem)
        XCTAssertTrue(server.text.hasPrefix("Brief's server had a problem (503)"))
    }

    func testFreshnessTreatsAFutureTimeAsJustNow() {
        // The phone's clock behind the server's.
        let f = Freshness.live(generatedAt: now.addingTimeInterval(120), checkedAt: now, status: nil,
                               isChecking: false, now: now)
        XCTAssertEqual(f.text, "Updated just now")
        XCTAssertEqual(f.tone, .normal)
    }

    func testPastBriefIsNeverStale() {
        let f = Freshness.snapshot(generatedAt: now.addingTimeInterval(-5 * 86400))
        XCTAssertEqual(f.tone, .normal)
        XCTAssertTrue(f.text.hasPrefix("Last updated "))
    }

    func testNewSinceNamesTheDayWhenItIsNotToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now)!
        let morning = calendar.date(bySettingHour: 9, minute: 40, second: 0, of: today)!
        let time = morning.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(Freshness.newSince(count: 14, since: morning, now: today, calendar: calendar),
                       "14 new since \(time)")

        let lastNight = morning.addingTimeInterval(-86400)
        XCTAssertEqual(Freshness.newSince(count: 3, since: lastNight, now: today, calendar: calendar),
                       "3 new since yesterday \(time)")

        let older = morning.addingTimeInterval(-3 * 86400)
        let text = Freshness.newSince(count: 8, since: older, now: today, calendar: calendar)
        XCTAssertTrue(text.hasPrefix("8 new since "))
        XCTAssertFalse(text.contains("yesterday"))
    }

    // MARK: Topic previews and hide read

    private func stories(_ prefix: String, _ count: Int) -> [Story] {
        (0..<count).map { Story.make(id: "\(prefix)\($0)", title: "Story \(prefix)\($0)", published: now) }
    }

    func testPreviewShowsThreeAndCountsTheWholeTopic() {
        let promoted = stories("top", 2)
        let section = stories("s", 5)
        let preview = TopicPreview.make(sectionStories: section, topicStories: promoted + section, sort: .hot,
                                        hiddenIDs: nil, isRead: { _ in false })
        XCTAssertEqual(preview.stories.map(\.id), ["s0", "s1", "s2"])
        // "See all 7": the Top stories count too.
        XCTAssertEqual(preview.total, 7)
        XCTAssertFalse(preview.allCaughtUp)
    }

    func testHideReadSkipsStoriesReadBeforeTheListAppeared() {
        let section = stories("s", 5)
        let readBefore: Set<String> = ["s0", "s2"]
        let preview = TopicPreview.make(sectionStories: section, topicStories: section, sort: .hot,
                                        hiddenIDs: readBefore, isRead: { readBefore.contains($0.id) })
        XCTAssertEqual(preview.stories.map(\.id), ["s1", "s3", "s4"])
        XCTAssertEqual(preview.total, 5)

        // Hide read off: everything shows, read or not.
        XCTAssertEqual(HideRead.visible(section, hidden: nil).count, 5)
        XCTAssertEqual(HideRead.visible(section, hidden: []).count, 5)
    }

    func testAllCaughtUpOnlyWhenHidingReadAndEverythingIsRead() {
        let section = stories("s", 2)
        let all = Set(section.map(\.id))
        let hidden = TopicPreview.make(sectionStories: section, topicStories: section, sort: .hot,
                                       hiddenIDs: all, isRead: { _ in true })
        XCTAssertTrue(hidden.allCaughtUp)
        XCTAssertTrue(hidden.stories.isEmpty)

        let shown = TopicPreview.make(sectionStories: section, topicStories: section, sort: .hot,
                                      hiddenIDs: nil, isRead: { _ in true })
        XCTAssertFalse(shown.allCaughtUp)
        XCTAssertEqual(shown.stories.count, 2)

        // A story that's in Top stories but unread means the topic isn't done.
        let promoted = stories("top", 1)
        let partly = TopicPreview.make(sectionStories: section, topicStories: promoted + section, sort: .hot,
                                       hiddenIDs: all, isRead: { all.contains($0.id) })
        XCTAssertFalse(partly.allCaughtUp)
    }

    func testPreviewFollowsTheSort() {
        let older = Story.make(id: "old", title: "Old", published: now.addingTimeInterval(-7200))
        let newer = Story.make(id: "new", title: "New", published: now)
        let preview = TopicPreview.make(sectionStories: [older, newer], topicStories: [older, newer],
                                        sort: .latest, hiddenIDs: nil, isRead: { _ in false })
        XCTAssertEqual(preview.stories.map(\.id), ["new", "old"])
    }

    func testTopicPageCountLine() {
        XCTAssertEqual(TopicPageView.countLine(total: 1, newCount: 0, hiddenCount: 0), "1 story")
        XCTAssertEqual(TopicPageView.countLine(total: 241, newCount: 5, hiddenCount: 30),
                       "241 stories · 5 new · 30 read hidden")
    }

    func testTopicHeaderWording() {
        XCTAssertEqual(TopicHeader.spoken("US", count: 241, newCount: 5), "US, 241 stories, 5 new")
        XCTAssertEqual(TopicHeader.spoken("AI", count: 1, newCount: 0), "AI, 1 story")
        XCTAssertEqual(TopicHeader.spoken("Top stories", count: nil, newCount: 0), "Top stories")
        XCTAssertEqual(TopicHeader.menuTitle("US", count: 241, newCount: 0), "US · 241")
        XCTAssertEqual(TopicHeader.menuTitle("US", count: 241, newCount: 5), "US · 241 · 5 new")
    }

    // MARK: Rows

    func testRowOutletShowsThePublisherAndHowManyOthers() {
        let one = Story.make(id: "a", title: "A", published: now,
                             sources: [source("Hacker News (100+ points)")])
        XCTAssertEqual(StoryCaption.outletText(one), "Hacker News")

        let many = Story.make(id: "b", title: "B", published: now,
                              sources: [source("The Wall Street Journal: U.S."), source("Reuters"), source("AP")])
        XCTAssertEqual(StoryCaption.outletText(many), "The Wall Street Journal +2")

        // Techmeme credits the original publisher; the row names the publisher.
        let techmeme = Story.make(id: "c", title: "C", published: now,
                                  sources: [source("Bloomberg via Techmeme"), source("Techmeme")])
        XCTAssertEqual(StoryCaption.outletText(techmeme), "Bloomberg +1")
        XCTAssertEqual(StoryCaption.rowOutlet("Techmeme"), "Techmeme")
        XCTAssertEqual(StoryCaption.rowOutlet("Bloomberg via Techmeme"), "Bloomberg")

        let none = Story.make(id: "d", title: "D", published: now)
        XCTAssertNil(StoryCaption.outletText(none))
    }

    func testRowIsSpokenHeadlineFirstWithItsLabel() {
        let rumor = Story.make(id: "r", title: "Switch 3 in 2027", published: now, label: "RUMOR-UNVERIFIED",
                               sources: [source("Wario64")])
        XCTAssertEqual(StoryCaption.spokenTitle(rumor), "Unverified rumor, not confirmed: Switch 3 in 2027")

        let plain = Story.make(id: "p", title: "Plain news", published: now, label: "REPORTED")
        XCTAssertEqual(StoryCaption.spokenTitle(plain), "Plain news")

        var opinion = Story.make(id: "o", title: "Why X matters", published: now)
        opinion.opinion = true
        XCTAssertEqual(StoryCaption.spokenTitle(opinion), "Opinion: Why X matters")
    }

    func testRowValueSaysStateAgeAndCoverage() {
        let story = Story.make(id: "s", title: "T", category: "Tech", published: now.addingTimeInterval(-2 * 3600),
                               sources: [source("The Verge"), source("Engadget"), source("CNET"), source("Wired")])
        XCTAssertEqual(StoryCaption.spokenDetails(story, isRead: false, isNew: true, isSaved: true,
                                                  showsTopic: true, now: now),
                       "New, 2 hours ago, The Verge and 3 other outlets, Tech, saved")
        XCTAssertEqual(StoryCaption.spokenDetails(story, isRead: true, isNew: false, isSaved: false,
                                                  showsTopic: false, now: now),
                       "Read, 2 hours ago, The Verge and 3 other outlets")
    }

    func testAgesNeverReadAsTheFuture() {
        XCTAssertEqual(RelativeAge.short(now.addingTimeInterval(-30), now: now), "Just now")
        XCTAssertEqual(RelativeAge.short(now.addingTimeInterval(300), now: now), "Just now")
        XCTAssertEqual(RelativeAge.spoken(now.addingTimeInterval(300), now: now), "just now")
        XCTAssertEqual(RelativeAge.spoken(now.addingTimeInterval(-3 * 3600), now: now), "3 hours ago")
    }

    // MARK: Pull to refresh and search

    func testPullToRefreshSaysWhatHappened() {
        XCTAssertEqual(Toast.refreshed(.updated(newCount: 14), status: nil).message, "14 new stories")
        XCTAssertEqual(Toast.refreshed(.updated(newCount: 1), status: nil).message, "1 new story")
        XCTAssertEqual(Toast.refreshed(.updated(newCount: 0), status: nil).message, "Brief updated")
        XCTAssertEqual(Toast.refreshed(.unchanged, status: nil).message, "You're up to date")
        XCTAssertEqual(Toast.refreshed(.failed, status: .offline).message, "You're offline")
        XCTAssertEqual(Toast.refreshed(.failed, status: .offline).systemImage, "wifi.slash")
    }

    func testRecentSearchesKeepTheNewestUniqueEight() {
        var stored = ""
        for term in ["nintendo", "  apple  ", "", "Nintendo"] {
            stored = RecentSearches.adding(term, to: stored)
        }
        // Case-insensitively unique, newest first, trimmed, empty ignored.
        XCTAssertEqual(RecentSearches.list(stored), ["Nintendo", "apple"])

        for i in 0..<10 { stored = RecentSearches.adding("term \(i)", to: stored) }
        let list = RecentSearches.list(stored)
        XCTAssertEqual(list.count, RecentSearches.limit)
        XCTAssertEqual(list.first, "term 9")

        // A pasted line break can't split one search into two.
        XCTAssertEqual(RecentSearches.list(RecentSearches.adding("a\nb", to: "")), ["a b"])
    }
}
