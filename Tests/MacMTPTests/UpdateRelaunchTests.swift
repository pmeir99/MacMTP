import Foundation
import XCTest
import UpdateSupport

final class UpdateRelaunchTests: XCTestCase {
    @MainActor
    func testRefusedQuitTimesOutInsteadOfLeavingSpinner() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        helper.arguments = ["10"]
        try helper.run()
        defer {
            if helper.isRunning { helper.terminate() }
            helper.waitUntilExit()
            try? FileManager.default.removeItem(at: workspace)
        }
        do {
            try await UpdateRelaunch.watchForFailedQuit(helper: helper, workspace: workspace, timeout: 0.15)
            XCTFail("A refused quit must report an error.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not quit"))
        }
        UpdateRelaunch.requestCancellation(in: workspace)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("cancel"), encoding: .utf8), "cancel")
    }

    @MainActor
    func testExitedHelperReportsFailureImmediately() async throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try helper.run()
        helper.waitUntilExit()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await UpdateRelaunch.watchForFailedQuit(helper: helper, workspace: FileManager.default.temporaryDirectory, timeout: 5)
            XCTFail("An exited helper must not leave the app installing.")
        } catch {
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        }
    }
}
