import SafariServices
import SwiftUI

struct StoryDetailView: View {
    @Environment(AppModel.self) private var store
    let story: Story
    @State private var safariLink: SafariLink?
    @AppStorage(SafariView.readerModeKey) private var readerMode = true

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        if let label = story.label { LabelBadge(label: label) }
                        ImportanceDots(level: story.importance)
                        Text(story.category)
                        Text("·")
                        Text(story.published, style: .relative) + Text(" ago")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(story.title)
                        .font(.title2.weight(.semibold))
                    Text(story.summary)
                        .font(.body)
                    if let first = story.sources.first {
                        Button {
                            safariLink = SafariLink(url: first.url)
                        } label: {
                            Label(readerMode ? "Read article (no ads)" : "Read article", systemImage: "doc.plaintext")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Sources (\(story.sources.count))") {
                ForEach(story.sources) { source in
                    Button {
                        safariLink = SafariLink(url: source.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(source.outlet).font(.subheadline.weight(.semibold))
                                if source.official {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel("Official source")
                                }
                            }
                            Text(source.title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let first = story.sources.first {
                ShareLink(item: first.url, subject: Text(story.title))
            }
        }
        .sheet(item: $safariLink) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
        .onAppear { store.markRead(story) }
    }
}

struct SafariLink: Identifiable {
    let url: URL
    var id: URL { url }
}

/// In-app Safari. With Reader view on (the default), articles open as clean text and images:
/// no ads, pop-ups or autoplay video. It also honors any Safari content blocker installed on the
/// phone, which covers pages that Reader can't simplify.
struct SafariView: UIViewControllerRepresentable {
    static let readerModeKey = "openArticlesInReader"
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = UserDefaults.standard.object(forKey: Self.readerModeKey) as? Bool ?? true
        config.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: config)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
