import UIKit
import XCTest
@testable import PersonalFeed

final class ImageLoaderTests: XCTestCase {
    func testPicturesAreShrunkToCardSizeKeepingTheirShape() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 4000, height: 3000)
        let photo = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let data = try XCTUnwrap(photo.jpegData(compressionQuality: 0.8))

        let shrunk = try XCTUnwrap(ImageLoader.downsample(data, maxPixelSize: ImageLoader.maxPixelSize)?.cgImage)
        XCTAssertLessThanOrEqual(max(shrunk.width, shrunk.height), Int(ImageLoader.maxPixelSize))
        XCTAssertGreaterThan(shrunk.width, 1000)
        XCTAssertEqual(Double(shrunk.width) / Double(shrunk.height), 4.0 / 3.0, accuracy: 0.01)

        XCTAssertNil(ImageLoader.downsample(Data("not a picture".utf8), maxPixelSize: 100))
    }
}
