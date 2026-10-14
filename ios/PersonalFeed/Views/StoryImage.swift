import SwiftUI
import UIKit

/// A story's picture at 16:9. The space is reserved before it loads so the feed never jumps, and
/// one that can't load shows the topic's colour and icon rather than an empty box.
struct StoryImage: View {
    let url: URL
    let topic: String
    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL, topic: String) {
        self.url = url
        self.topic = topic
        // Already in memory (scrolling back up): show it on the first frame, with no fade.
        _image = State(initialValue: ImageLoader.shared.cached(url))
    }

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .secondarySystemFill))
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else if failed {
                    let style = TopicStyle.of(topic)
                    Rectangle()
                        .fill(style.color.gradient)
                        .overlay {
                            Image(systemName: style.symbol)
                                .font(.system(size: 40, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
            .task(id: url) {
                guard image == nil, !failed else { return }
                do {
                    let loaded = try await ImageLoader.shared.image(for: url)
                    withAnimation(.easeOut(duration: 0.2)) { image = loaded }
                } catch {
                    // Scrolled away before it arrived: try again when it's back on screen.
                    if !Task.isCancelled { failed = true }
                }
            }
    }
}
