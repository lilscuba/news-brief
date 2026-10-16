import SafariServices
import XCTest
@testable import PersonalFeed

/// The pure pieces behind the story page, the article browser and Settings: bylines, the coverage
/// list, "More in <Topic>", the word-list editor, source health notes and save-status wording.
final class DetailViewTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// 3 PM on a fixed day, so "today" and "earlier this week" don't depend on when tests run.
    private var now: Date {
        calendar.date(bySettingHour: 15, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
    }

    private func at(hour: Int, minute: Int, daysAgo: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func source(_ outlet: String, _ published: Date?, title: String = "A headline",
                        id: String = UUID().uuidString, translatedFrom: String? = nil,
                        originalTitle: String? = nil) -> Source {
        Source(outlet: outlet, title: title, url: URL(string: "https://example.com/\(id)")!, official: false,
               translatedFrom: translatedFrom, originalTitle: originalTitle, published: published)
    }

    private func story(_ sources: [Source], published: Date? = nil, summary: String = "",
                       id: String = "s", category: String = "World") -> Story {
        Story(id: id, title: "Brazil heads to a runoff", summary: summary, importance: 1, label: "REPORTED",
              category: category, published: published ?? sources.compactMap(\.published).max() ?? now,
              outletCount: Set(sources.map(\.outlet)).count, sources: sources)
    }

    // MARK: Byline

    func testTimesAreAbsoluteAndNameTheDayWhenNotToday() {
        let morning = at(hour: 6, minute: 1)
        XCTAssertEqual(StoryPage.time(morning, now: now, calendar: calendar),
                       morning.formatted(.dateTime.hour().minute()))

        let lastNight = at(hour: 23, minute: 49, daysAgo: 1)
        let weekday = lastNight.formatted(.dateTime.weekday(.abbreviated))
        let yesterday = StoryPage.time(lastNight, now: now, calendar: calendar)
        XCTAssertTrue(yesterday.contains(weekday), yesterday)
        XCTAssertTrue(yesterday.contains(lastNight.formatted(.dateTime.hour().minute())), yesterday)

        let older = at(hour: 9, minute: 0, daysAgo: 10)
        let month = older.formatted(.dateTime.month(.abbreviated))
        XCTAssertTrue(StoryPage.time(older, now: now, calendar: calendar).contains(month))
    }

    func testBylineForOneOutletNamesItAndTheTime() {
        let s = story([source("The Guardian", at(hour: 6, minute: 1))])
        XCTAssertEqual(StoryPage.byline(s, outletCount: Coverage(s).outletCount, now: now, calendar: calendar),
                       "The Guardian · \(StoryPage.time(at(hour: 6, minute: 1), now: now, calendar: calendar))")
    }

    func testBylineSaysWhoReportedFirstAndWhenCoverageGrew() {
        let first = at(hour: 23, minute: 49, daysAgo: 1)
        let updated = at(hour: 6, minute: 1)
        let s = story([source("The Guardian", updated), source("Reuters", at(hour: 2, minute: 0)),
                       source("CS Monitor", first)])
        let t = { StoryPage.time($0, now: self.now, calendar: self.calendar) }
        XCTAssertEqual(StoryPage.byline(s, outletCount: Coverage(s).outletCount, now: now, calendar: calendar),
                       "First reported \(t(first)) by CS Monitor · Updated \(t(updated)) · 3 outlets")
    }

    func testBylineWithoutPerSourceTimesDoesNotGuessWhoWasFirst() {
        // Briefs saved by older builds have no per-source times.
        let s = story([source("The Guardian", nil), source("Reuters", nil)], published: at(hour: 6, minute: 1))
        let byline = StoryPage.byline(s, outletCount: 2, now: now, calendar: calendar)
        XCTAssertFalse(byline.contains("First reported"))
        XCTAssertEqual(byline, "The Guardian · \(StoryPage.time(at(hour: 6, minute: 1), now: now, calendar: calendar)) · 2 outlets")
    }

    func testReadButtonNamesThePublisher() {
        XCTAssertEqual(StoryPage.readTitle(story([source("The Guardian", now)])), "Read at The Guardian")
        XCTAssertEqual(StoryPage.readTitle(story([source("Hacker News (100+ points)", now)])), "Read at Hacker News")
        // Techmeme items link to the original article.
        XCTAssertEqual(StoryPage.readTitle(story([source("Bloomberg via Techmeme", now)])), "Read at Bloomberg")
        XCTAssertEqual(StoryPage.readTitle(story([source("", now)])), "Read Article")
    }

    func testMissingPreviewSaysSoAndNamesTheOutlet() {
        XCTAssertEqual(StoryPage.noPreview(story([source("Nikkei Asia", now)])),
                       "No preview from Nikkei Asia. Open the article to read it.")
        XCTAssertEqual(StoryPage.noPreview(story([])), "No preview for this story. Open the article to read it.")
    }

    func testTranslationNote() {
        let en = Locale(identifier: "en_US")
        XCTAssertNil(StoryPage.translationNote(source("NHK", now), locale: en))
        XCTAssertEqual(StoryPage.translationNote(source("NHK", now, translatedFrom: "ja", originalTitle: "決選投票へ"),
                                                 locale: en),
                       "Translated from Japanese: 決選投票へ")
        XCTAssertEqual(StoryPage.translationNote(source("Le Monde", now, translatedFrom: "fr"), locale: en),
                       "Translated from French")
    }

    // MARK: Coverage

    func testCoverageGroupsAnOutletNewestFirstAndMarksTheFirstReport() {
        let s = story([
            source("Euronews", at(hour: 10, minute: 0), title: "Lead"),
            source("CS Monitor", at(hour: 1, minute: 0), title: "Earliest"),
            source("Euronews", at(hour: 12, minute: 0), title: "Euronews again"),
            source("Reuters", at(hour: 11, minute: 0), title: "Reuters"),
        ])
        let c = Coverage(s)
        XCTAssertTrue(c.isShown)
        XCTAssertEqual(c.outletCount, 3)
        XCTAssertEqual(c.title, "Coverage from 3 outlets")
        XCTAssertEqual(c.outlets, ["Euronews", "Reuters", "CS Monitor"])
        XCTAssertEqual(c.entries.map(\.source.title), ["Euronews again", "Lead", "Reuters", "Earliest"])
        // The outlet is named once; its second headline sits under it.
        XCTAssertEqual(c.entries.map(\.startsOutlet), [true, false, true, true])
        XCTAssertEqual(c.entries.map(\.isFirst), [false, false, false, true])
        // Ids are positions, so two feeds carrying one link can't collide.
        XCTAssertEqual(Set(c.entries.map(\.id)).count, 4)
    }

    func testOneSourceHasNoCoverageListAndOneOutletIsNotAFirstReport() {
        XCTAssertFalse(Coverage(story([source("The Guardian", now)])).isShown)

        let twice = Coverage(story([source("Euronews", at(hour: 9, minute: 0)), source("Euronews", at(hour: 8, minute: 0))]))
        XCTAssertTrue(twice.isShown)
        XCTAssertEqual(twice.title, "2 headlines from Euronews")
        XCTAssertFalse(twice.entries.contains { $0.isFirst })
    }

    func testUndatedCoverageKeepsTheFeedOrder() {
        let c = Coverage(story([source("A", nil, title: "a"), source("B", nil, title: "b"), source("C", nil, title: "c")],
                               published: now))
        XCTAssertEqual(c.entries.map(\.source.title), ["a", "b", "c"])
        XCTAssertFalse(c.entries.contains { $0.isFirst })
    }

    func testLongCoverageShowsTheNewestFiveUntilAskedForAll() {
        let many = Coverage(story((0..<8).map { source("Outlet \($0)", at(hour: 14 - $0, minute: 0)) }))
        XCTAssertTrue(many.isCollapsed)
        XCTAssertEqual(many.visibleEntries(showingAll: false).count, Coverage.collapsedCount)
        XCTAssertEqual(many.visibleEntries(showingAll: false).first?.source.outlet, "Outlet 0")
        XCTAssertEqual(many.visibleEntries(showingAll: true).count, 8)
        XCTAssertEqual(many.showAllTitle, "Show all 8 outlets")

        // Hiding a single row would save nothing.
        let six = Coverage(story((0..<6).map { source("Outlet \($0)", at(hour: 14 - $0, minute: 0)) }))
        XCTAssertFalse(six.isCollapsed)
        XCTAssertEqual(six.visibleEntries(showingAll: false).count, 6)
    }

    func testSpokenCoverageRow() {
        let c = Coverage(story([source("Reuters", now.addingTimeInterval(-2 * 3600)),
                                source("NHK", now.addingTimeInterval(-5 * 3600), translatedFrom: "ja")]))
        let first = try? XCTUnwrap(c.entries.last)
        XCTAssertEqual(first.map { StoryPage.spokenCoverage($0, now: now) },
                       "\(RelativeAge.spoken(now.addingTimeInterval(-5 * 3600), now: now)), first report, translated")
    }

    // MARK: More in the topic

    func testMoreInTopicIsTheNextUnreadAfterThisStoryWrappingRound() {
        let topic = (0..<8).map { story([], published: now, id: "t\($0)", category: "US") }
        let read: Set<String> = ["t5"]
        let related: Set<String> = ["t6"]
        let more = StoryPage.moreInTopic(after: topic[3], in: topic, excluding: related,
                                         isRead: { read.contains($0.id) })
        XCTAssertEqual(more.map(\.id), ["t4", "t7", "t0"])

        // A story that isn't in today's topic (saved days ago) gets the topic's top unread.
        let elsewhere = story([], id: "old", category: "US")
        XCTAssertEqual(StoryPage.moreInTopic(after: elsewhere, in: topic, excluding: [], isRead: { _ in false }).map(\.id),
                       ["t0", "t1", "t2"])
        XCTAssertTrue(StoryPage.moreInTopic(after: topic[0], in: [topic[0]], excluding: [], isRead: { _ in false }).isEmpty)
    }

    // MARK: Article browser

    func testArticleBrowserHonoursTheLinksReaderFlag() {
        XCTAssertTrue(ArticleBrowser.configuration(reader: true).entersReaderIfAvailable)
        XCTAssertFalse(ArticleBrowser.configuration(reader: false).entersReaderIfAvailable)
    }

    @MainActor
    func testArticleBrowserCloseTellsTheModel() {
        var closed = 0
        let coordinator = ArticleBrowser.Coordinator(onDone: { closed += 1 })
        coordinator.safariViewControllerDidFinish(SFSafariViewController(url: URL(string: "https://example.com")!))
        XCTAssertEqual(closed, 1)
    }

    @MainActor
    func testOpenWithoutReaderOpensThatArticleOnly() {
        let store = IsolatedStore()
        defer { store.tearDown() }
        let model = AppModel.forTesting(clock: TestClock(now))
        let lead = source("The Guardian", now, id: "lead")
        let other = source("Reuters", now, id: "other")
        let s = story([lead, other])
        model.openArticle(s, reader: false)
        XCTAssertEqual(model.presentedArticle?.url, lead.url)
        XCTAssertEqual(model.presentedArticle?.reader, false)
        XCTAssertTrue(model.isRead(s))
        model.presentedArticle = nil
        model.openArticle(s, source: other)
        XCTAssertEqual(model.presentedArticle?.url, other.url)
        XCTAssertEqual(model.presentedArticle?.reader, ArticleLink.prefersReader)
    }

    // MARK: Settings

    func testWordListDedupesIgnoringCaseAndStopsAtTheLimit() {
        XCTAssertEqual(TermListEditor.addition(of: "  Fortnite \n", to: []), .add("Fortnite"))
        XCTAssertEqual(TermListEditor.addition(of: "fortnite", to: ["Fortnite"]), .duplicate("Fortnite"))
        XCTAssertEqual(TermListEditor.addition(of: "   ", to: []), .empty)
        XCTAssertEqual(TermListEditor.addition(of: String(repeating: "a", count: 80), to: []),
                       .add(String(repeating: "a", count: 60)))

        let full = (0..<UserSettings.maxTerms).map { "word\($0)" }
        XCTAssertEqual(TermListEditor.addition(of: "another", to: full), .full)
        // A duplicate is still reported as one at the limit.
        XCTAssertEqual(TermListEditor.addition(of: "WORD3", to: full), .duplicate("word3"))
        XCTAssertEqual(TermListEditor.addition(of: "another", to: Array(full.dropLast())), .add("another"))
    }

    func testSourceHealthNotes() {
        func info(status: String = "ok", latest: Date?, stale: Bool?) -> SourceInfo {
            SourceInfo(key: "k", title: "Corriere", category: "Europe", official: false, trusted: false,
                       mirror: false, status: status, latest: latest, stale: stale)
        }
        XCTAssertNil(SourcesSection.healthNote(info(latest: now, stale: false), now: now, calendar: calendar))
        XCTAssertNil(SourcesSection.healthNote(info(latest: now, stale: nil), now: now, calendar: calendar))
        XCTAssertEqual(SourcesSection.healthNote(info(status: "error", latest: now, stale: false), now: now,
                                                 calendar: calendar),
                       "Not responding right now")

        // `now` is in late September, so 40 days earlier is the same year: no year shown.
        let weeksAgo = calendar.date(byAdding: .day, value: -40, to: now)!
        XCTAssertEqual(SourcesSection.healthNote(info(latest: weeksAgo, stale: true), now: now, calendar: calendar),
                       "No new posts since \(weeksAgo.formatted(.dateTime.month(.abbreviated).day()))")

        let longAgo = calendar.date(byAdding: .year, value: -2, to: now)!
        XCTAssertTrue(SourcesSection.healthNote(info(latest: longAgo, stale: true), now: now, calendar: calendar)!
            .contains(longAgo.formatted(.dateTime.year())))
        XCTAssertEqual(SourcesSection.healthNote(info(latest: nil, stale: true), now: now, calendar: calendar),
                       "No new posts lately")

        // Feeds from before the pipeline sent `stale`: judged from the newest post (14 days).
        XCTAssertNotNil(SourcesSection.healthNote(info(latest: weeksAgo, stale: nil), now: now, calendar: calendar))
        let tenDays = calendar.date(byAdding: .day, value: -10, to: now)!
        XCTAssertNil(SourcesSection.healthNote(info(latest: tenDays, stale: nil), now: now, calendar: calendar))
        // The pipeline's say wins.
        XCTAssertNil(SourcesSection.healthNote(info(latest: weeksAgo, stale: false), now: now, calendar: calendar))
    }

    func testSaveStatusWordingAndAnnouncements() {
        XCTAssertEqual(SaveStatusLabel.rejectedText("Too many muted words."),
                       "Couldn't save: Too many muted words. Your account's settings were reloaded.")
        XCTAssertEqual(SaveStatusLabel.rejectedText("disabledSources has more than 500 entries"),
                       "Couldn't save: disabledSources has more than 500 entries. Your account's settings were reloaded.")
        XCTAssertEqual(SaveStatusLabel.rejectedText(" "),
                       "Couldn't save that change. Your account's settings were reloaded.")

        XCTAssertNil(SaveStatusLabel.announcement(for: .idle))
        XCTAssertNil(SaveStatusLabel.announcement(for: .saving))  // would only be noise
        XCTAssertEqual(SaveStatusLabel.announcement(for: .saved), "Saved")
        XCTAssertEqual(SaveStatusLabel.announcement(for: .failed("offline")), SaveStatusLabel.failedText)
        XCTAssertEqual(SaveStatusLabel.announcement(for: .rejected("Nope")),
                       "Couldn't save: Nope. Your account's settings were reloaded.")
    }

    func testBadgeFooterSaysWhenNotificationsAreNeeded() {
        XCTAssertTrue(SettingsView.badgeFooter(notificationStatus: .denied).hasSuffix("Needs notifications to be allowed."))
        XCTAssertTrue(SettingsView.badgeFooter(notificationStatus: .notDetermined).hasSuffix("Needs notifications to be allowed."))
        XCTAssertFalse(SettingsView.badgeFooter(notificationStatus: .authorized).contains("Needs notifications"))
    }

    /// The topic editor's VoiceOver "Move up" / "Move down" use these offsets.
    func testTopicMoveUpAndDownOffsets() {
        var s = UserSettings.default
        s.categories = ["AI", "Tech", "Gaming", "Deals"]
        s.moveCategories(fromOffsets: [2], toOffset: 1)  // Gaming up
        XCTAssertEqual(s.categories, ["AI", "Gaming", "Tech", "Deals"])
        s.moveCategories(fromOffsets: [0], toOffset: 2)  // AI down
        XCTAssertEqual(s.categories, ["Gaming", "AI", "Tech", "Deals"])
        s.setCategory("World", enabled: true)  // "More topics" follows at the end
        XCTAssertEqual(s.categories.last, "World")
    }
}
