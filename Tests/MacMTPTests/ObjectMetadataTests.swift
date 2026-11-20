import Foundation
import XCTest
@testable import MacMTP

final class ObjectMetadataTests: XCTestCase {
    func testStandardObjectInfoDatesAndImageDimensions() throws {
        var data = Data(repeating: 0, count: 52)
        // Standard ObjectInfo offsets: format 4, compressed size 8, image width 26, height 30.
        data[4] = 0x01; data[5] = 0x38 // EXIF/JPEG
        data[8] = 0x00; data[9] = 0x04 // 1024 bytes
        data[26] = 0x00; data[27] = 0x10 // 4096 pixels
        data[30] = 0x00; data[31] = 0x0c // 3072 pixels
        for value in ["photo.jpg", "20261119T120000", "20261120T130000"] {
            data.append(UInt8(value.utf16.count + 1))
            for unit in value.utf16 { data.append(UInt8(unit & 0xff)); data.append(UInt8(unit >> 8)) }
            data.append(contentsOf: [0, 0])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let item = try ObjectMetadata.decode(data, handle: 7, timestamp: formatter)
        XCTAssertEqual(item.id, 7)
        XCTAssertEqual(item.name, "photo.jpg")
        XCTAssertFalse(item.folder)
        XCTAssertEqual(item.size, 1024)
        XCTAssertEqual(item.pixelWidth, 4096)
        XCTAssertEqual(item.pixelHeight, 3072)
        XCTAssertEqual(item.created, formatter.date(from: "20261119T120000"))
        XCTAssertEqual(item.modified, formatter.date(from: "20261120T130000"))
    }

    func testTruncatedMetadataFailsWithoutOutOfBoundsRead() {
        let formatter = DateFormatter()
        for length in [0, 4, 8, 26, 30, 51, 52] {
            XCTAssertThrowsError(try ObjectMetadata.decode(Data(repeating: 0, count: length), handle: 1, timestamp: formatter))
        }
    }
}
