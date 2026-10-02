import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var working = false

    /// Every edit goes straight to the model, which rebuilds the brief and saves to the account.
    private var settings: Binding<UserSettings> {
        Binding(get: { model.settings }, set: { model.update($0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Feed") {
                    NavigationLink("Topics") {
                        Form { TopicsSection(settings: settings) }.navigationTitle("Topics")
                    }
                    NavigationLink("Sources") {
                        Form { SourcesSection(settings: settings, sources: model.feed?.sources ?? []) }
                            .navigationTitle("Sources")
                    }
                    NavigationLink("Muted words") {
                        Form {
                            Section {
                                TermListEditor(terms: settings.mutedWords, placeholder: "e.g. fortnite")
                            } footer: { Text("Stories mentioning these are hidden.") }
                        }.navigationTitle("Muted words")
                    }
                    NavigationLink("Boosted words") {
                        Form {
                            Section {
                                TermListEditor(terms: settings.boosts, placeholder: "e.g. nintendo")
                            } footer: { Text("Stories mentioning these rank higher in your brief.") }
                        }.navigationTitle("Boosted words")
                    }
                }
                Section("Notifications") {
                    NavigationLink("Breaking news alerts") {
                        Form { AlertsSection(settings: settings, watchlist: model.feed?.watchlist ?? []) }
                            .navigationTitle("Alerts")
                    }
                    NavigationLink("Morning brief") {
                        Form { BriefTimeSection(settings: settings) }.navigationTitle("Morning brief")
                    }
                    Button("Allow notifications") { Task { await model.enablePush() } }
                }
                if let error = model.errorMessage {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
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
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) {
                    working = true
                    Task { await model.deleteAccount(); working = false }
                }
            } message: {
                Text("This permanently removes your settings and stops all notifications. You can sign up again later.")
            }
        }
    }
}
