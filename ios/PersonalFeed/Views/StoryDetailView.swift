import SafariServices
import SwiftUI

struct StoryDetailView: View {
    @Environment(AppModel.self) private var store
    let story: Story
    @State private var safariLink: SafariLink?

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

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
