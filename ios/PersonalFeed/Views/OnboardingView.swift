import SwiftUI

/// First run after sign-up: pick topics, sources and alerts, then "Create my feed".
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = UserSettings.default
    @State private var step = 0
    @State private var saving = false

    private let titles = ["What do you follow?", "Pick your sources", "Breaking news alerts"]

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case 0: TopicsSection(settings: $draft)
                case 1: SourcesSection(settings: $draft, sources: model.feed?.sources ?? [])
                default:
                    AlertsSection(settings: $draft, watchlist: model.feed?.watchlist ?? [])
                    BriefTimeSection(settings: $draft)
                }
            }
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
                            Task { await model.finishOnboarding(with: draft) }
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
                draft = model.settings
                if model.feed == nil { await model.refresh() }
            }
        }
    }
}

// MARK: Reusable preference sections (onboarding + Settings)

struct TopicsSection: View {
    @Binding var settings: UserSettings

    private static let blurbs = [
        "AI": "Model launches, labs, research",
        "Tech": "Apple, Microsoft, Google, gadgets, the industry",
        "Gaming": "Consoles, releases, scoops, the business",
        "Deals": "Game and hardware sales, kept in their own section",
    ]

    var body: some View {
        Section {
            ForEach(UserSettings.allCategories, id: \.self) { name in
                Toggle(isOn: Binding(
                    get: { settings.categories.contains(name) },
                    set: { settings.setCategory(name, enabled: $0) }
                )) {
                    VStack(alignment: .leading) {
                        Text(name)
                        Text(Self.blurbs[name] ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            Text("You can change this any time in Settings.")
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
        let order = ["AI", "Tech", "Gaming"]
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

/// Add/remove a short list of words (muted words, boosts, alert keywords).
struct TermListEditor: View {
    @Binding var terms: [String]
    let placeholder: String
    @State private var newTerm = ""

    var body: some View {
        ForEach(terms, id: \.self) { term in
            Text(term)
        }
        .onDelete { terms.remove(atOffsets: $0) }
        HStack {
            TextField(placeholder, text: $newTerm)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        let t = String(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !t.isEmpty, !terms.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        terms.append(t)
        newTerm = ""
    }
}
