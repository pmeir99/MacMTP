import XCTest
@testable import MacMTP

final class FileNavigationTests: XCTestCase {
    func testArrowSelectionRespectsDisplayedOrderAndBoundaries() {
        let ids: [UInt32] = [40, 7, 90, 2]
        XCTAssertEqual(FileNavigation.destination(ids: ids, selected: 7, delta: 1), 90)
        XCTAssertEqual(FileNavigation.destination(ids: ids, selected: 90, delta: -1), 7)
        XCTAssertEqual(FileNavigation.destination(ids: ids, selected: 40, delta: -1), 40)
        XCTAssertEqual(FileNavigation.destination(ids: ids, selected: 2, delta: 1), 2)
    }

    func testGridUsesRowsAndHandlesIncompleteLastRow() {
        let ids: [UInt32] = [1, 2, 3, 4, 5]
        XCTAssertEqual(FileNavigation.destination(ids: ids, selected: 2, delta: 3), 5)
        XCTAssertEqual(FileNavigation.destination(ids: ids, selected: 5, delta: -3), 2)
        XCTAssertEqual(FileNavigation.destination(ids: ids, selected: 3, delta: 3), 5)
    }

    func testEmptyAndFilteredSelection() {
        XCTAssertNil(FileNavigation.destination(ids: [], selected: nil, delta: 1))
        XCTAssertEqual(FileNavigation.destination(ids: [8, 9], selected: 100, delta: 1), 8)
        XCTAssertEqual(FileNavigation.destination(ids: [8, 9], selected: nil, delta: -1), 9)
    }

    func testFileKindsAndSymbolsUseSystemTypes() {
        let photo = Entry(id: 1, name: "image.jpg", folder: false, size: 4, modified: nil)
        let video = Entry(id: 2, name: "video.mp4", folder: false, size: 4, modified: nil)
        let folder = Entry(id: 3, name: "Camera", folder: true, size: 0, modified: nil)
        XCTAssertNotEqual(photo.kind, "File")
        XCTAssertEqual(photo.symbol, "photo")
        XCTAssertEqual(video.symbol, "film")
        XCTAssertEqual(folder.kind, "Folder")
        XCTAssertEqual(folder.symbol, "folder.fill")
    }
}
