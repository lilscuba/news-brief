import ImageIO
import UIKit

/// Loads story pictures for the feed. Each one is shrunk to the size it's drawn at (a press photo
/// can take tens of megabytes decoded) and kept in memory, so scrolling back up shows it
/// instantly instead of fetching it again. Downloads are also cached on disk between launches.
final class ImageLoader: @unchecked Sendable {   // NSCache and URLSession are thread-safe
    static let shared = ImageLoader()
    /// Longest side, in pixels: a full-width card on the largest iPhone.
    static let maxPixelSize: CGFloat = 1290

    private let cache = NSCache<NSURL, UIImage>()
    private let session: URLSession

    init() {
        cache.totalCostLimit = 150 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 300 * 1024 * 1024)
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func image(for url: URL) async throws -> UIImage {
        if let hit = cached(url) { return hit }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let image = Self.downsample(data, maxPixelSize: Self.maxPixelSize) else {
            throw URLError(.cannotDecodeContentData)
        }
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
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
