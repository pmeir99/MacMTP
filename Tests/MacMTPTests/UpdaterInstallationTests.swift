import AppKit
import XCTest
import UpdateSupport

final class UpdaterInstallationTests: XCTestCase {
    func testHelperDismissesModalSheetQuitsAndReopensNewVersion() throws {
        try exerciseUpdate(refuseQuit: false)
    }

    func testRefusedQuitCancelsHelperWithoutReplacingApp() throws {
        try exerciseUpdate(refuseQuit: true)
    }

    private func exerciseUpdate(refuseQuit: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment["MACMTP_TEST_APP"] else {
            throw XCTSkip("Set MACMTP_TEST_APP to exercise the packaged update helper.")
        }
        let manager = FileManager.default
        let source = URL(fileURLWithPath: path).standardizedFileURL
        let version = try XCTUnwrap(Bundle(url: source)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let token = UUID()
        let workspace = UpdateFiles.workspace(token)
        var stage = "create workspace"
        do {
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
            if manager.fileExists(atPath: root.path) { try? manager.removeItem(at: root) }
            if manager.fileExists(atPath: workspace.path) { try? manager.removeItem(at: workspace) }
        }

        stage = "copy installed app"
        try UpdateFiles.tool("/usr/bin/ditto", [source.path, installed.path])
        let staged = workspace.appendingPathComponent("unpacked/MacMTP.app")
        stage = "stage update"
        try UpdateFiles.tool("/usr/bin/ditto", [source.path, staged.path])
        let info = installed.appendingPathComponent("Contents/Info.plist")
        var dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: info),
                                                                             format: nil) as? [String: Any])
        dictionary["CFBundleShortVersionString"] = "1.0.0"
        dictionary["CFBundleVersion"] = "1.0.0"
        try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0).write(to: info)
        let hostSource = canonicalRoot.appendingPathComponent("UpdateHost.swift")
        // Exercise the real AppKit quit barrier that the former exit(0) host skipped.
        // Compile the production handoff utility into an AppKit host at the installed executable path.
        let code = #"""
        import Foundation
        import AppKit
        import Darwin

        @MainActor final class Delegate: NSObject, NSApplicationDelegate {
            var window: NSWindow!
            var sheet: NSWindow!
            func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
                CommandLine.arguments.last == "refuse" ? .terminateCancel : .terminateNow
            }
            func applicationDidFinishLaunching(_ notification: Notification) {
                window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
                window.makeKeyAndOrderFront(nil)
                sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
                                 styleMask: [.titled], backing: .buffered, defer: false)
                sheet.preventsApplicationTerminationWhenModal = true
                window.beginSheet(sheet)
                Task { @MainActor in
                    do {
                        let args = CommandLine.arguments
                        guard args.count == 5 else { exit(2) }
                        let app = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
                            .deletingLastPathComponent().deletingLastPathComponent()
                        let helper = Process()
                        helper.executableURL = app.appendingPathComponent("Contents/Helpers/MacMTPUpdate")
                        helper.arguments = ["--install", args[1], args[2], String(getpid()), args[3]]
                        try helper.run()
                        let workspace = UpdateFiles.workspace(UUID(uuidString: args[3])!)
                        let deadline = ProcessInfo.processInfo.systemUptime + 30
                        while !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ready").path) {
                            if !helper.isRunning || ProcessInfo.processInfo.systemUptime > deadline { exit(3) }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                        // Reproduce the old bug before using the corrected production handoff.
                        NSApplication.shared.terminate(nil)
                        try await Task.sleep(for: .milliseconds(150))
                        guard self.window.attachedSheet === self.sheet else { exit(4) }
                        let marker = app.deletingLastPathComponent().appendingPathComponent("modal-blocked")
                        try Data("reproduced".utf8).write(to: marker)
                        do {
                            UpdateRelaunch.quit()
                            try await UpdateRelaunch.watchForFailedQuit(helper: helper, workspace: workspace,
                                                                       timeout: args[4] == "refuse" ? 0.25 : 8)
                            exit(5)
                        } catch {
                            guard args[4] == "refuse" else { exit(6) }
                            UpdateRelaunch.requestCancellation(in: workspace)
                            let stopDeadline = ProcessInfo.processInfo.systemUptime + 5
                            while helper.isRunning, ProcessInfo.processInfo.systemUptime < stopDeadline {
                                try await Task.sleep(for: .milliseconds(100))
                            }
                            guard !helper.isRunning else { exit(7) }
                            try Data("recovered".utf8).write(to: app.deletingLastPathComponent().appendingPathComponent("quit-refused"))
                            exit(0)
                        }
                    } catch { exit(6) }
                }
            }
        }
        @main struct Host {
            @MainActor static func main() {
                let application = NSApplication.shared
                application.setActivationPolicy(.regular)
                let delegate = Delegate()
                application.delegate = delegate
                withExtendedLifetime(delegate) { application.run() }
            }
        }
        """#
        try code.write(to: hostSource, atomically: true, encoding: .utf8)
        let executable = installed.appendingPathComponent("Contents/MacOS/MacMTP")
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let support = project.appendingPathComponent("Sources/UpdateSupport")
        stage = "compile AppKit update host"
        try UpdateFiles.tool("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-swift-version", "5", "-target", "arm64-apple-macos27.0",
            "-warnings-as-errors", hostSource.path, support.appendingPathComponent("Release.swift").path,
            support.appendingPathComponent("Relaunch.swift").path, "-o", executable.path])
        stage = "sign AppKit update host"
        try UpdateFiles.tool("/usr/bin/codesign", ["--force", "--sign", "-", installed.path])

        host.executableURL = executable
        host.arguments = [staged.path, version, token.uuidString, refuseQuit ? "refuse" : "allow"]
        stage = "launch AppKit update host"
        try host.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 70
        let rollback = canonicalRoot.appendingPathComponent(".MacMTP-update-\(token.uuidString).app")
        var succeeded = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            // Only the real helper removes this workspace, after receiving the
            // version receipt from the new app's visible main window.
            let complete = refuseQuit
                ? manager.fileExists(atPath: canonicalRoot.appendingPathComponent("quit-refused").path)
                : !manager.fileExists(atPath: workspace.path)
            if !host.isRunning, complete, !manager.fileExists(atPath: rollback.path) {
                succeeded = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let error = (try? String(contentsOf: UpdateFiles.root.appendingPathComponent("last-error"), encoding: .utf8)) ?? ""
        XCTAssertTrue(succeeded, "Update must replace the exiting host, reopen the new app, and remove its rollback copy. \(error)")
        if !host.isRunning { XCTAssertEqual(host.terminationStatus, 0) }
        else { XCTFail("The update host did not exit after installer readiness.") }
        XCTAssertTrue(manager.fileExists(atPath: canonicalRoot.appendingPathComponent("modal-blocked").path),
                      "The host must first reproduce AppKit blocking quit with its update sheet open.")
        stage = "verify preserved or updated app"
        let actualInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any]
        let expectedVersion = refuseQuit ? "1.0.0" : version
        XCTAssertEqual(actualInfo?["CFBundleShortVersionString"] as? String, expectedVersion,
                       "A refused quit must preserve the original Info.plist on disk.")
        do {
            try UpdateFiles.verifyApplication(installed, version: expectedVersion)
        } catch {
            let bundle = Bundle(url: installed)
            throw UpdateError.tool("\(error.localizedDescription) Expected \(expectedVersion); disk \(String(describing: actualInfo)); bundle \(String(describing: bundle?.infoDictionary)); path \(installed.path), resolved \(installed.resolvingSymlinksInPath().path)")
        }
        } catch {
            throw UpdateError.tool("Update regression failed during \(stage): \(error.localizedDescription)")
        }
    }
}
