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
            .onAppear {
                // Back on screen: the picture is usually still in ImageLoader's memory cache.
                if image == nil { image = ImageLoader.shared.cached(url) }
            }
            // Off screen only the cache holds the picture, so its memory limit applies. A List
            // keeps every row's state, so holding it here would keep every picture ever scrolled past.
            .onDisappear { image = nil }
            .task(id: url) {
                guard !Task.isCancelled else { return }
                // Also runs when the story's picture changes, so the old one never lingers.
                image = ImageLoader.shared.cached(url)
                var wait = 2.0
                while image == nil, !Task.isCancelled, ImageLoader.shared.canLoad(url) {
                    do {
                        let loaded = try await ImageLoader.shared.image(for: url)
                        // Scrolled away or the picture changed while it decoded. It's in the cache
                        // for next time; holding it here would keep it in memory off screen.
                        if Task.isCancelled { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            image = loaded
                            failed = false
                        }
                    } catch {
                        // Scrolled away before it arrived: it loads again when back on screen.
                        if Task.isCancelled { return }
                        // Offline, a timeout or a busy server: keep trying while it's on screen.
                        failed = true
                        try? await Task.sleep(for: .seconds(wait))
                        wait = min(wait * 3, 60)
                    }
                }
                if image == nil, !Task.isCancelled { failed = true }
            }
    }
}
