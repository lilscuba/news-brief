import UIKit
import XCTest
@testable import PersonalFeed

final class ImageLoaderTests: XCTestCase {
    private func picture(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testPicturesAreShrunkToCardSizeKeepingTheirShape() throws {
        let data = try XCTUnwrap(picture(CGSize(width: 4000, height: 3000)).jpegData(compressionQuality: 0.8))

        let shrunk = try XCTUnwrap(ImageLoader.downsample(data, maxPixelSize: ImageLoader.maxPixelSize)?.cgImage)
        XCTAssertLessThanOrEqual(max(shrunk.width, shrunk.height), Int(ImageLoader.maxPixelSize))
        XCTAssertGreaterThan(shrunk.width, 1000)
        XCTAssertEqual(Double(shrunk.width) / Double(shrunk.height), 4.0 / 3.0, accuracy: 0.01)

        XCTAssertNil(ImageLoader.downsample(Data("not a picture".utf8), maxPixelSize: 100))
    }

    func testTrackingPixelsAreGivenUpOnAndRealPicturesAreKept() async throws {
        let loader = ImageLoader()
        let dir = FileManager.default.temporaryDirectory

        let pixel = dir.appending(path: "pixel-\(UUID().uuidString).png")
        try XCTUnwrap(picture(CGSize(width: 1, height: 1)).pngData()).write(to: pixel)
        do {
            _ = try await loader.image(for: pixel)
            XCTFail("a tracking pixel isn't a story's picture")
        } catch {}
        XCTAssertFalse(loader.canLoad(pixel), "not requested again every time its card scrolls into view")

        let photo = dir.appending(path: "photo-\(UUID().uuidString).jpg")
        try XCTUnwrap(picture(CGSize(width: 400, height: 300)).jpegData(compressionQuality: 0.8)).write(to: photo)
        let loaded = try await loader.image(for: photo)
        XCTAssertEqual(loaded.cgImage?.width, 400)
        XCTAssertTrue(loader.canLoad(photo))
        XCTAssertNotNil(loader.cached(photo), "kept in memory for scrolling back up")
    }
}
