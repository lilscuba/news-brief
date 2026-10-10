import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var working = false
    @State private var path: [SettingsPage] = []
    @AppStorage(ArticleLink.readerModeKey) private var readerMode = true
    @AppStorage(AppModel.showBadgeKey) private var showBadge = true

    /// Every edit goes straight to the model, which rebuilds the brief and saves to the account.
    private var settings: Binding<UserSettings> {
        Binding(get: { model.settings }, set: { model.update($0) })
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                feedSection
                readingSection
                notificationsSection
                if let error = model.accountError {
                    Section {
                        Label {
                            Text(error)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                        .font(.footnote)
                    }
                }
                Section {
                    Button("Sign out") {
                        working = true
                        Task { await model.signOut(); working = false }
                    }
                    Button("Delete account", role: .destructive) { confirmDelete = true }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Signed in with Apple. Your account holds only your feed settings and the push token for this phone.")
                }
            }
            .disabled(working)
            .navigationTitle("Settings")
            // Registered once, at the stack root; every push is a value.
            .navigationDestination(for: SettingsPage.self) { page($0) }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    working = true
                    Task { await model.deleteAccount(); working = false }
                }
            } message: {
                Text("This permanently removes your settings and stops all notifications. You can sign up again later.")
            }
        }
        .task { await model.refreshNotificationStatus() }
        #if DEBUG
        .task { if path.isEmpty, let page = SettingsPage.demoRoute { path = [page] } }
        #endif
    }

    // MARK: Sections

    private var feedSection: some View {
        let s = model.settings
        return Section("Feed") {
            NavigationLink(value: SettingsPage.topics) {
                LabeledContent("Topics", value: "\(s.categories.count)")
            }
            NavigationLink(value: SettingsPage.sources) {
                LabeledContent("Sources", value: s.disabledSources.isEmpty ? "All on" : "\(s.disabledSources.count) off")
            }
            NavigationLink(value: SettingsPage.mutedWords) {
                LabeledContent("Muted words", value: s.mutedWords.isEmpty ? "None" : "\(s.mutedWords.count)")
            }
            NavigationLink(value: SettingsPage.boostedWords) {
                LabeledContent("Boosted words", value: s.boosts.isEmpty ? "None" : "\(s.boosts.count)")
            }
        }
    }

    private var readingSection: some View {
        Group {
            Section {
                Toggle("Open articles in Reader view", isOn: $readerMode)
            } header: {
                Text("Reading")
            } footer: {
                Text("When a page supports it: just the text and images, without most ads and pop-ups. Other pages open as usual. To open one article the other way, touch and hold its Read button. Safari content blockers you install work here too.")
            }
            Section {
                Toggle("Show new-story count on app icon", isOn: $showBadge)
                    .onChange(of: showBadge) { _, on in
                        if !on { model.clearBadge() }
                    }
            } footer: {
                Text(Self.badgeFooter(notificationStatus: model.notificationStatus))
            }
        }
    }

    private var notificationsSection: some View {
        Section {
            NavigationLink("Breaking news alerts", value: SettingsPage.alerts)
            NavigationLink("Morning brief", value: SettingsPage.morningBrief)
            switch model.notificationStatus {
            case .denied:
                Button {
                    model.openSystemNotificationSettings()
                } label: {
                    Label("Turn On in iOS Settings", systemImage: "gear")
                }
            case .notDetermined:
                Button("Allow Notifications") { Task { await model.enablePush() } }
            default:
                Label("Notifications are on", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Notifications")
        } footer: {
            if model.notificationStatus == .denied {
                Text("Notifications are off for Brief, so alerts and the morning brief can't reach you.")
            }
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func page(_ page: SettingsPage) -> some View {
        switch page {
        case .topics:
            Form { TopicsSection(settings: settings, saveState: model.saveState) }
                .topicsEditing()
                .navigationTitle("Topics")
        case .sources:
            Form {
                saveStatus
                SourcesSection(settings: settings, sources: model.feed?.sources ?? [])
            }
            .navigationTitle("Sources")
        case .mutedWords:
            Form {
                saveStatus
                Section {
                    TermListEditor(terms: settings.mutedWords, placeholder: "e.g. fortnite")
                } footer: {
                    Text("Stories with one of these words in a headline are hidden. Whole words only: “ice” doesn't hide “police”, and plurals count, so “game” also hides “games”.")
                }
            }
            .navigationTitle("Muted words")
        case .boostedWords:
            Form {
                saveStatus
                Section {
                    TermListEditor(terms: settings.boosts, placeholder: "e.g. nintendo")
                } footer: {
                    Text("Stories with one of these words in a headline rank higher in your brief. Whole words only: “AI” doesn't boost “said”, and plurals count.")
                }
            }
            .navigationTitle("Boosted words")
        case .alerts:
            Form {
                saveStatus
                AlertsSection(settings: settings, watchlist: model.feed?.watchlist ?? [])
            }
            .navigationTitle("Alerts")
        case .morningBrief:
            Form {
                saveStatus
                BriefTimeSection(settings: settings)
            }
            .navigationTitle("Morning brief")
        }
    }

    /// Where the last change is, at the top of the page so it's seen on a long list.
    private var saveStatus: some View {
        Section {
        } footer: {
            SaveStatusHeader(state: model.saveState)
        }
    }

    static func badgeFooter(notificationStatus: UNAuthorizationStatus) -> String {
        let text = "The number of new, unread stories since your last visit, updated when Brief checks for news in the background."
        switch notificationStatus {
        case .denied, .notDetermined: return text + " Needs notifications to be allowed."
        default: return text
        }
    }
}

/// "Changes save automatically." and where the last change is. A line is kept for the status so
/// the list doesn't jump when "Saving…" appears under the reader's finger.
private struct SaveStatusHeader: View {
    let state: AppModel.SaveState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Changes save automatically.")
            ZStack(alignment: .leading) {
                Label("Saved", systemImage: "checkmark.circle.fill").hidden()
                SaveStatusLabel(state: state)
            }
        }
    }
}

/// The screens under Settings, pushed by value.
enum SettingsPage: String, Hashable, Codable, Sendable {
    case topics, sources, mutedWords, boostedWords, alerts, morningBrief

    #if DEBUG
    /// `-BriefDemoRoute settings:topics` opens a page for simulator screenshots (see DemoMode).
    static var demoRoute: SettingsPage? {
        guard let route = DemoMode.route, route.hasPrefix("settings:") else { return nil }
        return SettingsPage(rawValue: String(route.dropFirst("settings:".count)))
    }
    #endif
}
