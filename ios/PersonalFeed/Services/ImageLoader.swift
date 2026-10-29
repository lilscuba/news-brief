import ImageIO
import UIKit

/// Loads story pictures for the feed. Each one is shrunk to the size it's drawn at (a press photo
/// can take tens of megabytes decoded) and kept in memory, so scrolling back up shows it
/// instantly instead of fetching it again. Downloads are also cached on disk between launches.
final class ImageLoader: @unchecked Sendable {   // NSCache, URLSession and the lock are thread-safe
    static let shared = ImageLoader()
    /// Longest side, in pixels: a full-width card on the largest iPhone.
    static let maxPixelSize: CGFloat = 1290
    /// Anything smaller is a tracking pixel or an icon, not a story's picture.
    static let minPixelSize = 64

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession
    private let lock = NSLock()
    /// Pictures that will never load (a dead link, a file that isn't a picture), so they aren't
    /// requested again every time their card scrolls into view.
    private var unloadable: Set<URL> = []

    init() {
        cache.totalCostLimit = 150 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 300 * 1024 * 1024)
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    /// False after a failure that trying again can't fix. No connection, a timeout or a busy
    /// server are worth another try.
    func canLoad(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !unloadable.contains(url)
    }

    func image(for url: URL) async throws -> UIImage {
        if let hit = cached(url) { return hit }
        guard canLoad(url) else { throw URLError(.fileDoesNotExist) }
        let (data, response) = try await session.data(from: url)
        try Task.checkCancellation()   // its card scrolled away: skip the decode
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if ![408, 429].contains(http.statusCode) && http.statusCode < 500 { giveUp(on: url) }
            throw URLError(.badServerResponse)
        }
        guard let image = Self.downsample(data, maxPixelSize: Self.maxPixelSize),
              let cgImage = image.cgImage,
              min(cgImage.width, cgImage.height) >= Self.minPixelSize else {
            giveUp(on: url)
            throw URLError(.cannotDecodeContentData)
        }
        cache.setObject(image, forKey: url as NSURL, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    private func giveUp(on url: URL) {
        lock.lock()
        defer { lock.unlock() }
        unloadable.insert(url)
    }

    /// Decodes straight to the smaller size, so the full-size picture never sits in memory.
    static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,   // decode here, off the main thread
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
