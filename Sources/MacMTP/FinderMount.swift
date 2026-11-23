import AppKit
import Darwin
import FinderSupport
import SwiftUI

private struct PhoneMountBackend: DAVBackend {
    let device: Device
    let session: UUID
    let storages: [Storage]
    func perform(_ operation: DAVOperation) async throws -> DAVResult {
        try await device.finderOperation(operation, session: session, storages: storages)
    }
}

@MainActor
final class FinderMountController: ObservableObject {
    static let shared = FinderMountController()
    @Published private(set) var ownsDevice = false
    @Published private(set) var changing = false
    @Published private(set) var location: URL?
    @Published private(set) var message = ""
    @Published private(set) var failure: String?
    private var canMount: (@MainActor () -> Bool)?
    private var device: Device?
    private var server: DAVServer?
    private var directory: URL?
    private var monitor: Task<Void, Never>?

    func attach(_ device: Device, canMount: @escaping @MainActor () -> Bool) {
        if !ownsDevice { self.device = device; self.canMount = canMount }
    }
    func open() { if let location { NSWorkspace.shared.open(location) } }
    func mount(writable: Bool) async {
        guard !ownsDevice, !changing, let device else { return }
        guard canMount?() == true else { failure = "Finish the current transfer or connection operation before mounting."; return }
        changing = true; ownsDevice = true; failure = nil; message = "Preparing Finder mount…"
        defer { changing = false }
        do {
            let storages = try await device.connect()
            guard !storages.isEmpty else { throw DeviceError.unavailable }
            let session = await device.sessionIdentifier
            let backend = PhoneMountBackend(device: device, session: session, storages: storages)
            let server = try DAVServer(backend: backend, writable: writable)
            self.server = server
            let address = try await server.start()
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacMTP/FinderMounts", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.directory = directory
            let flags = writable ? "nosuid,nodev,noexec" : "rdonly,nosuid,nodev,noexec"
            try await Self.command("/sbin/mount_webdav", ["-v", "MacMTP", "-o", flags, address.absoluteString, directory.path])
            guard Self.isMounted(directory) else { throw DAVError(503, "macOS did not finish mounting the phone") }
            location = directory; message = writable ? "Mounted in Finder · Read and write" : "Mounted in Finder · Read only"
            open()
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    if !Self.isMounted(directory) { self.finish(); return }
                    if await device.sessionIdentifier != session {
                        self.failure = "The phone session ended. Eject this mount, reconnect the phone, and mount again."
                        self.message = "Phone disconnected"
                    }
                }
            }
        } catch {
            // A failed mount command can still leave a live volume. Never remove its directory.
            if let directory, Self.isMounted(directory) {
                location = directory; failure = "Mount setup did not finish: \(error.localizedDescription). Eject the volume before retrying."
            } else { finish(); failure = error.localizedDescription }
        }
    }
    @discardableResult
    func unmount() async -> Bool {
        guard ownsDevice, !changing else { return !ownsDevice }
        changing = true; failure = nil; message = "Ejecting phone…"
        defer { changing = false }
        do {
            if let directory, Self.isMounted(directory) {
                try await Self.command("/sbin/umount", [directory.path])
                guard !Self.isMounted(directory) else { throw DAVError(503, "The phone is still mounted") }
            }
            finish(); return true
        } catch {
            failure = "Close files and Finder copy operations using the phone, then eject again. \(error.localizedDescription)"
            message = "Could not eject phone"; return false
        }
    }
    private func finish() {
        monitor?.cancel(); monitor = nil
        server?.stop(); server = nil; location = nil; ownsDevice = false; message = ""
        // Only remove our empty mount point. Never recursively delete a mounted phone tree.
        if let directory, !Self.isMounted(directory) { _ = directory.path.withCString { Darwin.rmdir($0) } }
        directory = nil
        NotificationCenter.default.post(name: .macmtpFinderDidUnmount, object: nil)
    }
    static func isMounted(_ directory: URL) -> Bool {
        // mountedVolumeURLs reports the mount root itself, not its parent filesystem.
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []).contains {
            $0.standardizedFileURL.path == directory.standardizedFileURL.path
        }
    }
    static func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) async throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled || Date() >= deadline {
                process.terminate()
                throw DAVError(503, "The mount operation timed out or was cancelled")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // Don't expose the private URL/token from mount_webdav diagnostics.
            let safe = text.replacingOccurrences(of: "http://[^\\s]+", with: "[private local mount]", options: .regularExpression)
            throw DAVError(503, safe.isEmpty ? "macOS could not complete the mount operation" : String(safe.prefix(1200)))
        }
    }
}

extension Notification.Name {
    static let macmtpFinderDidUnmount = Notification.Name("MacMTPFinderDidUnmount")
}

final class MacMTPApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let mount = FinderMountController.shared
            guard mount.ownsDevice else { return .terminateNow }
            Task { @MainActor in sender.reply(toApplicationShouldTerminate: await mount.unmount()) }
            return .terminateLater
        }
    }
}
