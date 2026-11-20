import XCTest
@testable import MacMTP

final class DirectoryContentTests: XCTestCase {
    private let camera = Entry(id: 10, name: "Camera", folder: true, size: 0, modified: nil)
    private let photo = Entry(id: 11, name: "photo.jpg", folder: false, size: 10, modified: nil)

    func testNavigationClearsParentContentsBeforeUSBResponds() {
        var content = DirectoryContent()
        content.begin(parent: .max, cached: nil)
        content.receive([camera], parent: .max)
        content.begin(parent: camera.id, cached: nil)
        XCTAssertTrue(content.loading)
        XCTAssertTrue(content.entries.isEmpty, "The parent folder must never appear inside its own contents.")
        XCTAssertNil(content.loadedParent)
        content.receive([photo], parent: camera.id)
        XCTAssertFalse(content.loading)
        XCTAssertEqual(content.entries.map(\.id), [11])
    }

    func testLateResponseCannotReplaceAnotherFolder() {
        var content = DirectoryContent()
        content.begin(parent: 10, cached: nil)
        content.begin(parent: 20, cached: nil)
        XCTAssertFalse(content.receive([photo], parent: 10))
        XCTAssertTrue(content.loading)
        XCTAssertTrue(content.entries.isEmpty)
    }

    func testCachedFolderAndDisconnect() {
        var content = DirectoryContent()
        content.begin(parent: 10, cached: [photo])
        XCTAssertFalse(content.loading)
        XCTAssertEqual(content.loadedParent, 10)
        XCTAssertEqual(content.entries.map(\.id), [11])
        content.reset()
        XCTAssertTrue(content.entries.isEmpty)
        XCTAssertNil(content.requestedParent)
        XCTAssertNil(content.loadedParent)
    }
}
