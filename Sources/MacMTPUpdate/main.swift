import Foundation
import AppKit
import Darwin
import UpdateSupport

func executablePath(_ pid: pid_t) -> String? {
    // libproc defines PROC_PIDPATHINFO_MAXSIZE as 4 * MAXPATHLEN.
    var bytes = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &bytes, UInt32(bytes.count))
    guard length > 0 else { return nil }
    let path = bytes.prefix(Int(length)).prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
    return String(decoding: path, as: UTF8.self)
}

func install() throws {
    let args = CommandLine.arguments
    if args.count == 4, args[1] == "--verify" {
        try UpdateFiles.verifyApplication(URL(fileURLWithPath: args[2]), version: args[3])
        return
    }
    guard args.count == 6, args[1] == "--install",
          let version = AppVersion(args[3]), let pid = Int32(args[4]),
          let token = UUID(uuidString: args[5]), pid > 1 else { throw UpdateError.invalidApplication }
    let helper = URL(fileURLWithPath: args[0]).standardizedFileURL.resolvingSymlinksInPath()
    let installed = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let expectedParent = installed.appendingPathComponent("Contents/MacOS/MacMTP").path
    guard getppid() == pid else {
        throw UpdateError.tool("The updater could not verify its parent process.")
    }
    guard let parentPath = executablePath(pid),
          URL(fileURLWithPath: parentPath).resolvingSymlinksInPath().path == expectedParent else {
        throw UpdateError.tool("The updater could not verify the running MacMTP executable.")
    }
    guard FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path) else {
        throw UpdateError.permission
    }
    guard let old = Bundle(url: installed)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
          let oldVersion = AppVersion(old) else {
        throw UpdateError.tool("The installed MacMTP version could not be read.")
    }
    guard version > oldVersion else {
        throw UpdateError.tool("The update version must be newer than installed MacMTP \(oldVersion.value).")
    }

    let workspace = UpdateFiles.workspace(token)
    let source = URL(fileURLWithPath: args[2]).standardizedFileURL
    guard source.path == workspace.appendingPathComponent("unpacked/MacMTP.app").path else { throw UpdateError.invalidArchive }
    try UpdateFiles.verifyApplication(source, version: version.value)
    let replacement = installed.deletingLastPathComponent()
        .appendingPathComponent(".MacMTP-update-\(token.uuidString).app")
    guard !FileManager.default.fileExists(atPath: replacement.path) else { throw UpdateError.invalidApplication }
    try UpdateFiles.tool("/usr/bin/ditto", [source.path, replacement.path])
    var removeReplacement = true
    defer {
        if removeReplacement { try? FileManager.default.removeItem(at: replacement) }
    }
    try UpdateFiles.verifyApplication(replacement, version: version.value)
    try Data("ready".utf8).write(to: workspace.appendingPathComponent("ready"), options: .atomic)
    let deadline = ProcessInfo.processInfo.systemUptime + 60
    while executablePath(pid) == expectedParent {
        if FileManager.default.fileExists(atPath: workspace.appendingPathComponent("cancel").path) {
            throw UpdateError.tool("The update was canceled because MacMTP could not quit. The installed app has not been replaced.")
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw UpdateError.timeout }
        usleep(100_000)
    }

    do {
        try UpdateTransaction.swap(installed, replacement)
    } catch {
        try? Data(error.localizedDescription.utf8).write(to: UpdateFiles.root.appendingPathComponent("last-error"),
                                                       options: .atomic)
        _ = try? UpdateFiles.tool("/usr/bin/open", ["-n", installed.path])
        throw error
    }
    removeReplacement = false
    do {
        try UpdateFiles.tool("/usr/bin/open", ["-n", installed.path, "--args",
                                              "--macmtp-update-token", token.uuidString])
        let launchDeadline = ProcessInfo.processInfo.systemUptime + 30
        let receipt = workspace.appendingPathComponent("launched")
        while (try? String(contentsOf: receipt, encoding: .utf8)) != version.value {
            guard ProcessInfo.processInfo.systemUptime < launchDeadline else { throw UpdateError.timeout }
            usleep(100_000)
        }
        removeReplacement = true
        try? FileManager.default.removeItem(at: workspace)
    } catch {
        // The old app remains at replacement after the swap. Restore and reopen it.
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: UpdateFiles.identifier)
            .filter { $0.bundleURL?.standardizedFileURL.path == installed.path }
        for app in instances { app.terminate() }
        let quitDeadline = ProcessInfo.processInfo.systemUptime + 2
        while instances.contains(where: { !$0.isTerminated }),
              ProcessInfo.processInfo.systemUptime < quitDeadline { usleep(100_000) }
        for app in instances where !app.isTerminated { app.forceTerminate() }
        try UpdateTransaction.swap(installed, replacement)
        removeReplacement = true
        try? Data(error.localizedDescription.utf8).write(to: UpdateFiles.root.appendingPathComponent("last-error"),
                                                       options: .atomic)
        _ = try? UpdateFiles.tool("/usr/bin/open", ["-n", installed.path])
        throw error
    }
}

do {
    try install()
} catch {
    let root = UpdateFiles.root
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try? Data(error.localizedDescription.utf8).write(to: root.appendingPathComponent("last-error"), options: .atomic)
    fputs("MacMTP update failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
