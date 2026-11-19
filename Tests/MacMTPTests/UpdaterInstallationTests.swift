import AppKit
import XCTest
import UpdateSupport

final class UpdaterInstallationTests: XCTestCase {
    func testHelperReplacesExitingAppAndReopensNewVersion() throws {
        guard let path = ProcessInfo.processInfo.environment["MACMTP_TEST_APP"] else {
            throw XCTSkip("Set MACMTP_TEST_APP to exercise the packaged update helper.")
        }
        let manager = FileManager.default
        let source = URL(fileURLWithPath: path).standardizedFileURL
        let version = try XCTUnwrap(Bundle(url: source)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let token = UUID()
        let workspace = UpdateFiles.workspace(token)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        let canonicalRoot = root.resolvingSymlinksInPath()
        let installed = canonicalRoot.appendingPathComponent("MacMTP.app")
        let host = Process()
        defer {
            if host.isRunning { host.terminate() }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: UpdateFiles.identifier)
                where app.bundleURL?.resolvingSymlinksInPath().path == installed.path {
                app.forceTerminate()
            }
            try? manager.removeItem(at: root)
            try? manager.removeItem(at: workspace)
        }

        try UpdateFiles.tool("/usr/bin/ditto", [source.path, installed.path])
        let staged = workspace.appendingPathComponent("unpacked/MacMTP.app")
        try UpdateFiles.tool("/usr/bin/ditto", [source.path, staged.path])
        let info = installed.appendingPathComponent("Contents/Info.plist")
        var dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: info),
                                                                             format: nil) as? [String: Any])
        dictionary["CFBundleShortVersionString"] = "1.0.0"
        dictionary["CFBundleVersion"] = "1.0.0"
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: info)
        let hostSource = canonicalRoot.appendingPathComponent("UpdateHost.swift")
        // A small parent process follows the app's real readiness-and-exit protocol.
        // The helper and the relaunched app are the actual packaged executables.
        let code = #"""
        import Foundation
        import Darwin
        let args = CommandLine.arguments
        guard args.count == 4 else { exit(2) }
        let app = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let helper = Process()
        helper.executableURL = app.appendingPathComponent("Contents/Helpers/MacMTPUpdate")
        helper.arguments = ["--install", args[1], args[2], String(getpid()), args[3]]
        try helper.run()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let ready = caches.appendingPathComponent("com.meir.macmtp/Updates")
            .appendingPathComponent(args[3]).appendingPathComponent("ready")
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !FileManager.default.fileExists(atPath: ready.path) {
            if !helper.isRunning || ProcessInfo.processInfo.systemUptime > deadline { exit(3) }
            usleep(100_000)
        }
        exit(0)
        """#
        try code.write(to: hostSource, atomically: true, encoding: .utf8)
        let executable = installed.appendingPathComponent("Contents/MacOS/MacMTP")
        try UpdateFiles.tool("/usr/bin/xcrun", ["swiftc", hostSource.path, "-o", executable.path])
        try UpdateFiles.tool("/usr/bin/codesign", ["--force", "--sign", "-", installed.path])

        host.executableURL = executable
        host.arguments = [staged.path, version, token.uuidString]
        try host.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 70
        let rollback = canonicalRoot.appendingPathComponent(".MacMTP-update-\(token.uuidString).app")
        var succeeded = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            // Only the real helper removes this workspace, after receiving the
            // version receipt from the new app's visible main window.
            if !host.isRunning, !manager.fileExists(atPath: workspace.path),
               !manager.fileExists(atPath: rollback.path) {
                succeeded = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let error = (try? String(contentsOf: UpdateFiles.root.appendingPathComponent("last-error"), encoding: .utf8)) ?? ""
        XCTAssertTrue(succeeded, "Update must replace the exiting host, reopen the new app, and remove its rollback copy. \(error)")
        if !host.isRunning { XCTAssertEqual(host.terminationStatus, 0) }
        else { XCTFail("The update host did not exit after installer readiness.") }
        try UpdateFiles.verifyApplication(installed, version: version)
    }
}
