import AppKit
import XCTest
import UpdateSupport

final class AppLaunchTests: XCTestCase {
    func testPackagedAppConfirmsItOpened() throws {
        guard let path = ProcessInfo.processInfo.environment["MACMTP_TEST_APP"] else {
            throw XCTSkip("Set MACMTP_TEST_APP to run the packaged app launch check.")
        }
        let appURL = URL(fileURLWithPath: path).standardizedFileURL
        let token = UUID()
        let workspace = UpdateFiles.workspace(token)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: UpdateFiles.identifier)
                where app.bundleURL?.standardizedFileURL.path == appURL.path {
                app.forceTerminate()
            }
            try? FileManager.default.removeItem(at: workspace)
        }
        try UpdateFiles.tool("/usr/bin/open", ["-n", appURL.path, "--args",
                                              "--macmtp-update-token", token.uuidString])
        let receipt = workspace.appendingPathComponent("launched")
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        while !FileManager.default.fileExists(atPath: receipt.path),
              ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let expected = try XCTUnwrap(Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(try String(contentsOf: receipt, encoding: .utf8), expected,
                       "The same launch acknowledgment used by the updater must arrive from the packaged app.")
    }
}
