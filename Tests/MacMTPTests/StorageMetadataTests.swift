import AppKit
import XCTest
@testable import MacMTP

final class StorageMetadataTests: XCTestCase {
    private func info(type: UInt16, name: String, volume: String = "") -> Data {
        var data = Data(repeating: 0, count: 26)
        data[0] = UInt8(type & 0xff)
        data[1] = UInt8(type >> 8)
        for value in [name, volume] {
            data.append(UInt8(value.utf16.count + 1))
            for unit in value.utf16 { data.append(UInt8(unit & 0xff)); data.append(UInt8(unit >> 8)) }
            data.append(contentsOf: [0, 0])
        }
        return data
    }

    func testStorageIconsUseDeviceMetadataRatherThanNamesOrIDs() throws {
        let builtIn = try StorageMetadata.decode(info(type: 3, name: "Internal shared storage"), id: 0x10001)
        let card = try StorageMetadata.decode(info(type: 4, name: "Camera archives"), id: 0x20001)
        XCTAssertEqual(builtIn.kind, .internalStorage)
        XCTAssertEqual(builtIn.kind.symbol, "internaldrive")
        XCTAssertEqual(card.kind, .removable)
        XCTAssertEqual(card.kind.symbol, "sdcard")
        XCTAssertEqual(card.name, "Camera archives")
        XCTAssertEqual(try StorageMetadata.decode(info(type: 3, name: "SD card"), id: 7).kind, .internalStorage)
    }

    func testReadOnlyAndUnknownStorageTypes() throws {
        XCTAssertEqual(try StorageMetadata.decode(info(type: 1, name: "System"), id: 1).kind, .internalStorage)
        XCTAssertEqual(try StorageMetadata.decode(info(type: 2, name: "Card"), id: 2).kind, .removable)
        let unknown = try StorageMetadata.decode(info(type: 0x8001, name: "Other device storage"), id: 3)
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertEqual(unknown.kind.symbol, "externaldrive")
    }

    func testMissingNamesAndTruncatedData() throws {
        XCTAssertEqual(try StorageMetadata.decode(info(type: 4, name: "", volume: "MEDIA"), id: 1).name, "MEDIA")
        XCTAssertEqual(try StorageMetadata.decode(info(type: 3, name: ""), id: 1).name, "Internal storage")
        XCTAssertThrowsError(try StorageMetadata.decode(Data(repeating: 0, count: 26), id: 1))
    }

    func testInternalStorageComesFirstWithoutReorderingCards() {
        let items = [Storage(id: 4, name: "Unknown"),
                     Storage(id: 3, name: "Card B", kind: .removable),
                     Storage(id: 2, name: "Phone", kind: .internalStorage),
                     Storage(id: 1, name: "Card A", kind: .removable)]
        XCTAssertEqual(Storage.ordered(items).map(\.id), [2, 3, 1, 4])
        XCTAssertTrue(Storage.ordered([]).isEmpty)
    }

    func testStorageSymbolsExistInSystemLibrary() {
        for kind in [Storage.Kind.internalStorage, .removable, .unknown] {
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil))
        }
    }
}
