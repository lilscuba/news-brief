import SwiftUI

/// First run after sign-up: pick topics, sources and alerts, then "Create my feed".
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = UserSettings.default
    /// Until the reader changes something, the draft follows the account's settings as they load
    /// (after a reinstall they arrive a moment later and must not be replaced by defaults).
    @State private var edited = false
    @State private var step = 0
    @State private var saving = false

    private let titles = ["What do you follow?", "Pick your sources", "Breaking news alerts"]

    /// The time-zone fill-in on the last step isn't the reader's edit.
    private var editableDraft: Binding<UserSettings> {
        Binding(get: { draft }, set: { new in
            var old = draft
            old.brief.timezone = new.brief.timezone
            if new != old { edited = true }
            draft = new
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case 0: TopicsSection(settings: editableDraft)
                case 1: SourcesSection(settings: editableDraft, sources: model.feed?.sources ?? [])
                default:
                    AlertsSection(settings: editableDraft, watchlist: model.feed?.watchlist ?? [])
                    BriefTimeSection(settings: editableDraft)
                    if let error = model.accountError {
                        Section {
                            Label { Text(error) } icon: {
                                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .topicsEditing(step == 0)
            .navigationTitle(titles[step])
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step > 0 { Button("Back") { step -= 1 } }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        if step < titles.count - 1 {
                            step += 1
                        } else {
                            saving = true
                            Task {
                                await model.finishOnboarding(with: draft)
                                saving = false  // still here: the account couldn't be reached
                            }
                        }
                    } label: {
                        Text(step < titles.count - 1 ? "Next" : "Create my feed")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || draft.categories.isEmpty)
                }
            }
            .task {
                if !edited { draft = model.settings }
                if model.feed == nil { await model.refresh() }
            }
            .onChange(of: model.settings) { _, account in
                if !edited { draft = account }
            }
        }
    }
}

// MARK: Reusable preference sections (onboarding + Settings)

/// The topics editor (onboarding, Settings and Today's "Edit Topics…"). "Following" is in the
/// reader's order, which Today's sections follow: drag to reorder, minus to unfollow. "More topics"
/// lists the rest; following one adds it at the end.
struct TopicsSection: View {
    @Binding var settings: UserSettings
    /// Shown in Settings, where every change saves to the account by itself. Nil in onboarding.
    var saveState: AppModel.SaveState? = nil

    static let blurbs = [
        "AI": "Model launches, labs, research",
        "Tech": "Apple, Microsoft, Google, gadgets, the industry",
        "Gaming": "Consoles, releases, scoops, the business",
        "US": "US news and politics from outlets across the spectrum",
        "World": "Global headlines from English-language outlets",
        "Europe": "UK, Ireland, Germany, France, Spain, Italy, Ukraine and more. Non-English outlets are translated.",
        "Japan": "Japan Times, Nikkei Asia, NHK, Asahi and more. Japanese outlets are translated.",
        "Korea": "Yonhap, Korea Herald, Korea Times, Chosun Ilbo and more. Korean outlets are translated.",
        "Deals": "Game and hardware sales, kept in their own section",
    ]

    var body: some View {
        let following = settings.categories
        Section {
            if following.isEmpty {
                Text("You're not following any topics yet. Add one below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(following.enumerated()), id: \.element) { index, name in
                TopicEditorRow(name: name, blurb: Self.blurbs[name], isFollowing: true) {
                    unfollow(name)
                }
                .accessibilityAction(named: "Unfollow") { unfollow(name) }
                .accessibilityActions {
                    if index > 0 {
                        Button("Move up") { move(index, to: index - 1) }
                    }
                    if index < following.count - 1 {
                        Button("Move down") { move(index, to: index + 2) }
                    }
                }
            }
            .onMove { settings.moveCategories(fromOffsets: $0, toOffset: $1) }
        } header: {
            Text("Following")
        } footer: {
            if following.count > 1 {
                Text("Drag to reorder. Today shows your topics in this order.")
            }
        }

        Section {
            let more = settings.unfollowedCategories
            if more.isEmpty {
                Text("You're following every topic.")
                    .foregroundStyle(.secondary)
            }
            // Ids of their own: with the same id in both sections the list carried the row across
            // on follow, and it arrived in Following without its drag handle.
            ForEach(more, id: \.moreTopicID) { name in
                Button {
                    withAnimation { settings.setCategory(name, enabled: true) }
                } label: {
                    TopicEditorRow(name: name, blurb: Self.blurbs[name], isFollowing: false)
                }
                .tint(.primary)
                .accessibilityLabel("Follow \(name)")
                .accessibilityHint(Self.blurbs[name] ?? "")
            }
        } header: {
            Text("More topics")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(saveState == nil ? "You can change this any time in Settings."
                                      : "Changes save automatically.")
                if let saveState { SaveStatusLabel(state: saveState) }
            }
        }
    }

    private func unfollow(_ name: String) {
        withAnimation { settings.setCategory(name, enabled: false) }
    }

    private func move(_ index: Int, to destination: Int) {
        withAnimation { settings.moveCategories(fromOffsets: [index], toOffset: destination) }
    }
}

extension View {
    /// For the Form that hosts a TopicsSection: always editing, so "Following" shows its drag
    /// handles without an Edit button. It has to be set on the list itself (a Section's own
    /// environment doesn't reach the cells), and only rows with onMove get handles.
    func topicsEditing(_ active: Bool = true) -> some View {
        environment(\.editMode, .constant(active ? .active : .inactive))
    }
}

private extension String {
    var moreTopicID: String { "more:" + self }
}

/// A topic in the editor: a red minus (unfollow) or green plus (follow), its icon, name and blurb.
private struct TopicEditorRow: View {
    let name: String
    let blurb: String?
    let isFollowing: Bool
    var unfollow: (() -> Void)? = nil
    @ScaledMetric(relativeTo: .body) private var control: CGFloat = 22
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Side by side, the control, icon and drag handle left the blurb a few letters a
                // line ("Mod-el launc-hes"), so the blurb gets the row's width and the icon goes.
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        followControl
                        Text(name)
                    }
                    blurbText
                }
            } else {
                HStack(spacing: 12) {
                    followControl
                    TopicIcon(name: name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                        blurbText
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityHint(blurb ?? "")
    }

    @ViewBuilder
    private var followControl: some View {
        if isFollowing {
            Button {
                unfollow?()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: control))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
            .buttonStyle(.borderless)
            .accessibilityHidden(true)  // the row's "Unfollow" action
        } else {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: control))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var blurbText: some View {
        if let blurb {
            Text(blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// "Saving…", "Saved" or why it didn't save, under the topic list and at the top of the other
/// Settings pages. Changes are read out, since they happen away from where the reader is looking.
struct SaveStatusLabel: View {
    let state: AppModel.SaveState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { label }
            .onChange(of: state) { _, new in
                if let text = Self.announcement(for: new) {
                    AccessibilityNotification.Announcement(text).post()
                }
            }
    }

    @ViewBuilder
    private var label: some View {
        switch state {
        case .idle:
            EmptyView()
        case .saving:
            Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
        case .saved:
            Label {
                Text("Saved")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failed:
            Label {
                Text(Self.failedText)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        case .rejected(let message):
            Label {
                Text(Self.rejectedText(message)).foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    static let failedText = "Couldn't save yet. Your choices are kept on this phone and will sync when you're back online."

    /// The account's reason, then what happened to the change.
    static func rejectedText(_ message: String) -> String {
        var reason = message.trimmingCharacters(in: .whitespacesAndNewlines)
        while reason.last == "." { reason.removeLast() }
        let lead = reason.isEmpty ? "Couldn't save that change." : "Couldn't save: \(reason)."
        return "\(lead) Your account's settings were reloaded."
    }

    /// What VoiceOver says when the state changes ("Saving…" would only be noise).
    static func announcement(for state: AppModel.SaveState) -> String? {
        switch state {
        case .idle, .saving: nil
        case .saved: "Saved"
        case .failed: failedText
        case .rejected(let message): rejectedText(message)
        }
    }
}

struct SourcesSection: View {
    @Binding var settings: UserSettings
    let sources: [SourceInfo]

    private struct SourceGroup: Identifiable {
        let category: String
        let sources: [SourceInfo]
        var id: String { category }
    }

    private var groups: [SourceGroup] {
        let order = UserSettings.allCategories
        let grouped = Dictionary(grouping: sources, by: \.category)
        return grouped.keys
            .sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
            .map { key in SourceGroup(category: key, sources: (grouped[key] ?? []).sorted { $0.title < $1.title }) }
    }

    var body: some View {
        if sources.isEmpty {
            Section { ProgressView("Loading sources…") }
        }
        ForEach(groups) { group in
            Section(group.category) {
                ForEach(group.sources) { source in
                    Toggle(isOn: Binding(
                        get: { settings.isSourceEnabled(source.key) },
                        set: { settings.setSource(source.key, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(source.title)
                                if source.official {
                                    Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.tint)
                                        .accessibilityLabel("Official")
                                }
                                if source.trusted {
                                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange)
                                        .accessibilityLabel("Trusted reporter")
                                }
                            }
                            // A feed that stopped posting (or answering) explains a quiet topic.
                            if let note = Self.healthNote(source, now: .now) {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        Section {
        } footer: {
            Label("Official source", systemImage: "checkmark.seal.fill")
            Label("Reporter or outlet with a strong scoop record", systemImage: "star.fill")
        }
    }

    /// The pipeline's `[health] stale_days`, for feeds built before it sent `stale` itself.
    static let staleAfterDays = 14.0

    /// "No new posts since Aug 8" for a feed that answers but has gone quiet for weeks, "Not
    /// responding right now" for one that doesn't answer; nil for a healthy one.
    static func healthNote(_ source: SourceInfo, now: Date, calendar: Calendar = .current) -> String? {
        if source.status != "ok" { return "Not responding right now" }
        let quiet = source.stale ?? source.latest.map { now.timeIntervalSince($0) > staleAfterDays * 86400 } ?? false
        guard quiet else { return nil }
        guard let latest = source.latest else { return "No new posts lately" }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if calendar.component(.year, from: latest) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return "No new posts since \(latest.formatted(style))"
    }
}

struct AlertsSection: View {
    @Binding var settings: UserSettings
    let watchlist: [WatchRule]

    var body: some View {
        Section {
            Toggle("Official announcements", isOn: $settings.alerts.official)
            Toggle("Scoops from trusted reporters", isOn: $settings.alerts.trusted)
            Toggle("Stories confirmed by 2+ outlets", isOn: $settings.alerts.corroborated)
            Stepper("At most \(settings.alerts.maxPerDay) a day", value: $settings.alerts.maxPerDay, in: 0...20)
        } header: {
            Text("Push me when…")
        } footer: {
            Text("Trusted and multi-outlet alerts only fire for stories on your watchlist. Deals never alert.")
        }
        Section {
            Toggle("Use the built-in watchlist", isOn: $settings.alerts.defaultWatchlist)
            if settings.alerts.defaultWatchlist && !watchlist.isEmpty {
                Text(watchlist.map(\.name).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TermListEditor(terms: $settings.alerts.keywords, placeholder: "Add a keyword, e.g. Zelda")
        } header: {
            Text("Watchlist")
        } footer: {
            Text("Your keywords match whole words in headlines.")
        }
    }
}

struct BriefTimeSection: View {
    @Binding var settings: UserSettings

    var body: some View {
        Section {
            Toggle("Morning brief notification", isOn: $settings.brief.notify)
            if settings.brief.notify {
                Picker("Time", selection: $settings.brief.hour) {
                    ForEach(0..<24, id: \.self) { h in
                        Text(Self.label(hour: h)).tag(h)
                    }
                }
            }
        } footer: {
            Text("Time zone: \(settings.brief.timezone)")
        }
        .onAppear { settings.brief.timezone = TimeZone.current.identifier }
    }

    static func label(hour: Int) -> String {
        var c = DateComponents()
        c.hour = hour
        let date = Calendar.current.date(from: c) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// Add/remove a short list of words (muted words, boosts, alert keywords). Words are compared
/// without case, and the list stops at the account's limit instead of failing to save.
struct TermListEditor: View {
    @Binding var terms: [String]
    let placeholder: String
    var limit = UserSettings.maxTerms
    @State private var newTerm = ""
    @State private var note: String?

    enum Addition: Equatable {
        case add(String)
        case empty
        /// Already listed (as written there).
        case duplicate(String)
        case full
    }

    /// What adding `input` would do: trimmed, at most 60 characters.
    static func addition(of input: String, to terms: [String], limit: Int = UserSettings.maxTerms) -> Addition {
        let term = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !term.isEmpty else { return .empty }
        if let existing = terms.first(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            return .duplicate(existing)
        }
        return terms.count < limit ? .add(term) : .full
    }

    var body: some View {
        ForEach(terms, id: \.self) { term in
            Text(term)
        }
        .onDelete { terms.remove(atOffsets: $0) }
        if terms.count >= limit {
            Label("That's the limit of \(limit). Delete one to add another.", systemImage: "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                TextField(placeholder, text: $newTerm)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .onChange(of: newTerm) { _, text in
                        if !text.isEmpty { note = nil }
                    }
                Button("Add", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        switch Self.addition(of: newTerm, to: terms, limit: limit) {
        case .add(let term):
            terms.append(term)
            newTerm = ""
        case .duplicate(let existing):
            newTerm = ""
            note = "“\(existing)” is already on the list."
            AccessibilityNotification.Announcement(note ?? "").post()
        case .empty, .full:
            break
        }
    }
}
