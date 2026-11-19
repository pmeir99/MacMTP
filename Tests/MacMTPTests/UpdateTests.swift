import Foundation
import XCTest
import UpdateSupport

final class UpdateTests: XCTestCase {
    func testVersionsCompareNumerically() throws {
        XCTAssertGreaterThan(try XCTUnwrap(AppVersion("1.10.0")), try XCTUnwrap(AppVersion("1.9.9")))
        XCTAssertGreaterThan(try XCTUnwrap(AppVersion("2.0.0")), try XCTUnwrap(AppVersion("1.99.99")))
        XCTAssertEqual(AppVersion("1.1.0"), AppVersion("1.1.0"))
        for invalid in ["1.0", "v1.1.0", "1.1.0-beta", "1.-1.0", "01.1.0", "", "1.1.0/../app"] {
            XCTAssertNil(AppVersion(invalid))
        }
    }

    func testOnlyNewerStableOfficialReleasesAreAccepted() throws {
        let installed = try XCTUnwrap(AppVersion("1.0.0"))
        XCTAssertEqual(try release().update(after: installed)?.0.value, "1.1.0")
        XCTAssertNil(try release().update(after: XCTUnwrap(AppVersion("1.1.0"))))
        XCTAssertNil(try release().update(after: XCTUnwrap(AppVersion("2.0.0"))))
        XCTAssertThrowsError(try release(draft: true).update(after: installed))
        XCTAssertThrowsError(try release(prerelease: true).update(after: installed))
        XCTAssertThrowsError(try release(url: "http://github.com/pmeir99/MacMTP/releases/download/v1.1.0/MacMTP.zip").update(after: installed))
        XCTAssertThrowsError(try release(url: "https://example.com/MacMTP.zip").update(after: installed))
        XCTAssertThrowsError(try release(url: "https://github.com/other/MacMTP/releases/download/v1.1.0/MacMTP.zip").update(after: installed))
        XCTAssertThrowsError(try release(digest: nil).update(after: installed))
        XCTAssertThrowsError(try release(digest: "sha256:bad").update(after: installed))
    }

    func testChecksumDetectsChangedBytes() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("download")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try UpdateFiles.checksum(file),
                       "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let original = try UpdateFiles.checksum(file)
        try Data("abd".utf8).write(to: file)
        XCTAssertNotEqual(try UpdateFiles.checksum(file), original)
    }

    func testAtomicSwapAndRollbackPreserveBothBundles() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("MacMTP.app")
        let replacement = folder.appendingPathComponent(".replacement.app")
        for (url, version) in [(original, "old"), (replacement, "new")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try Data(version.utf8).write(to: url.appendingPathComponent("version"))
        }
        try UpdateTransaction.swap(original, replacement)
        XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("version"), encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: replacement.appendingPathComponent("version"), encoding: .utf8), "old")
        try UpdateTransaction.swap(original, replacement)
        XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("version"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: replacement.appendingPathComponent("version"), encoding: .utf8), "new")
        XCTAssertThrowsError(try UpdateTransaction.swap(original, original))
        XCTAssertThrowsError(try UpdateTransaction.swap(original, folder.appendingPathComponent("missing.app")))
        XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("version"), encoding: .utf8), "old")
    }

    func testActualDittoArchiveAndUnsafeEntries() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("MacMTP.app")
        let contents = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("executable".utf8).write(to: contents.appendingPathComponent("MacMTP"))
        let zip = folder.appendingPathComponent("MacMTP.zip")
        try UpdateFiles.tool("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path])
        XCTAssertNoThrow(try UpdateArchive.validate(zip))
        var traversal = try Data(contentsOf: zip)
        let root = Data("MacMTP.app".utf8)
        let unsafe = Data("../outside".utf8)
        var searchStart = 0
        while let range = traversal.range(of: root, in: searchStart..<traversal.count) {
            traversal.replaceSubrange(range, with: unsafe)
            searchStart = range.upperBound
        }
        try traversal.write(to: zip)
        XCTAssertThrowsError(try UpdateArchive.validate(zip))

        // A symbolic link could redirect extraction outside its private workspace.
        try FileManager.default.createSymbolicLink(at: contents.appendingPathComponent("outside"),
                                                  withDestinationURL: folder)
        try FileManager.default.removeItem(at: zip)
        try UpdateFiles.tool("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        XCTAssertThrowsError(try UpdateArchive.validate(zip))
        try Data("broken archive".utf8).write(to: zip)
        XCTAssertThrowsError(try UpdateArchive.validate(zip))
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func release(url: String = "https://github.com/pmeir99/MacMTP/releases/download/v1.1.0/MacMTP.zip",
                         digest: String? = "sha256:" + String(repeating: "a", count: 64),
                         draft: Bool = false, prerelease: Bool = false) throws -> GitHubRelease {
        var asset: [String: Any] = ["name": "MacMTP.zip", "size": 100, "browser_download_url": url]
        asset["digest"] = digest
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v1.1.0", "body": "Release notes", "draft": draft,
            "prerelease": prerelease, "assets": [asset]
        ])
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}
