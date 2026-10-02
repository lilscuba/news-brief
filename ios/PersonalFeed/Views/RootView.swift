import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .restoring:
                ProgressView()
            case .signedOut:
                SignInView()
            case .onboarding:
                OnboardingView()
            case .ready:
                MainTabs()
            }
        }
        .animation(.default, value: model.phase)
        .sheet(item: Binding(
            get: { model.pendingURL.map { SafariLink(url: $0) } },
            set: { model.pendingURL = $0?.url }
        )) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "newspaper") }
            HistoryView()
                .tabItem { Label("History", systemImage: "calendar") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

struct TodayView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if let brief = model.brief {
                    BriefView(brief: brief, status: model.errorMessage)
                        .refreshable { await model.refresh() }
                } else if model.isLoading {
                    ProgressView("Building your feed…")
                } else {
                    ContentUnavailableView {
                        Label("No news yet", systemImage: "tray")
                    } description: {
                        Text(model.errorMessage ?? "Your feed appears here as soon as it's ready.")
                    } actions: {
                        Button("Try again") { Task { await model.refresh() } }
                    }
                }
            }
            .navigationTitle("Today")
            .navigationDestination(for: Story.self) { StoryDetailView(story: $0) }
        }
    }
}

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List(model.history) { brief in
                NavigationLink(value: brief) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(brief.displayDate).font(.headline)
                        Text(brief.top.first?.title ?? brief.headline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .overlay {
                if model.history.isEmpty {
                    ContentUnavailableView("No history yet", systemImage: "calendar",
                                           description: Text("Your briefs from the last 30 days are kept on this phone."))
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: Brief.self) { brief in
                BriefView(brief: brief).navigationTitle(brief.displayDate).navigationBarTitleDisplayMode(.inline)
            }
            .navigationDestination(for: Story.self) { StoryDetailView(story: $0) }
        }
    }
}
