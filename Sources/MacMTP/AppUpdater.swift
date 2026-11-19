import AppKit
import SwiftUI
import UpdateSupport

@MainActor
final class AppUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, current, available, downloading, verifying, installing, failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = 0.0
    @Published private(set) var newVersion = ""
    @Published private(set) var releaseNotes = ""
    @Published var showWindow = false
    @Published var blockedByTransfer = false
    @Published var automaticallyChecks: Bool {
        didSet { UserDefaults.standard.set(automaticallyChecks, forKey: "checkForUpdatesAutomatically") }
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    private var candidate: (AppVersion, GitHubRelease.Asset)?
    private var job: Task<Void, Never>?
    private var checkedOnLaunch = false
    private var helper: Process?

    var isInstalling: Bool { [.downloading, .verifying, .installing].contains(phase) }

    init() {
        automaticallyChecks = UserDefaults.standard.object(forKey: "checkForUpdatesAutomatically") as? Bool ?? true
    }

    func launched() {
        UpdateFiles.acknowledgeLaunch(arguments: CommandLine.arguments, version: currentVersion)
        guard !checkedOnLaunch else { return }
        checkedOnLaunch = true
        let errorURL = UpdateFiles.root.appendingPathComponent("last-error")
        if let message = try? String(contentsOf: errorURL, encoding: .utf8) {
            try? FileManager.default.removeItem(at: errorURL)
            phase = .failed(message)
            showWindow = true
        } else if automaticallyChecks {
            Task { await check(background: true) }
        }
    }

    func check(background: Bool = false) async {
        guard !isInstalling, phase != .checking else { return }
        phase = .checking
        candidate = nil
        do {
            guard let installed = AppVersion(currentVersion) else { throw UpdateError.invalidApplication }
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/pmeir99/MacMTP/releases/latest")!)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("MacMTP/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  response.url?.scheme == "https", response.url?.host == "api.github.com",
                  data.count <= 1_048_576 else { throw UpdateError.invalidRelease }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            if let update = try release.update(after: installed) {
                candidate = update
                newVersion = update.0.value
                releaseNotes = release.body ?? ""
                phase = .available
                showWindow = true
            } else {
                phase = .current
            }
        } catch {
            phase = .failed(error.localizedDescription)
            if !background { showWindow = true }
        }
    }

    func install() {
        guard let candidate, !blockedByTransfer, phase == .available else { return }
        phase = .downloading
        progress = 0
        job = Task {
            let token = UUID()
            let workspace = UpdateFiles.workspace(token)
            var handedOff = false
            defer {
                if !handedOff { try? FileManager.default.removeItem(at: workspace) }
                job = nil
            }
            do {
                let installed = Bundle.main.bundleURL.standardizedFileURL
                guard installed.pathExtension == "app",
                      installed.resolvingSymlinksInPath().path == installed.path,
                      FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path)
                else { throw UpdateError.permission }
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let archive = workspace.appendingPathComponent("MacMTP.zip")
                let download = UpdateDownload(destination: archive, size: candidate.1.size) { [weak self] amount in
                    Task { @MainActor in
                        if self?.phase == .downloading { self?.progress = amount }
                    }
                }
                _ = try await download.download(candidate.1.browser_download_url)
                try Task.checkCancellation()
                phase = .verifying
                let source = try await Task.detached {
                    guard try UpdateFiles.checksum(archive) == candidate.1.digest else {
                        throw UpdateError.checksumMismatch
                    }
                    try UpdateArchive.validate(archive)
                    let unpacked = workspace.appendingPathComponent("unpacked", isDirectory: true)
                    try UpdateFiles.tool("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
                    let source = unpacked.appendingPathComponent("MacMTP.app")
                    try UpdateFiles.verifyApplication(source, version: candidate.0.value)
                    return source
                }.value
                try Task.checkCancellation()
                guard !blockedByTransfer else {
                    throw UpdateError.tool("Finish the current transfer before installing this update.")
                }
                let process = Process()
                process.executableURL = installed.appendingPathComponent("Contents/Helpers/MacMTPUpdate")
                process.arguments = ["--install", source.path, candidate.0.value,
                                     String(ProcessInfo.processInfo.processIdentifier), token.uuidString]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                helper = process
                let deadline = ProcessInfo.processInfo.systemUptime + 30
                while !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("ready").path) {
                    guard process.isRunning, ProcessInfo.processInfo.systemUptime < deadline else {
                        throw UpdateError.timeout
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                phase = .installing
                handedOff = true
                NSApplication.shared.terminate(nil)
            } catch {
                if helper?.isRunning == true { helper?.terminate() }
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    phase = .available
                } else {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelDownload() { job?.cancel() }
}

struct SoftwareUpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text(title).font(.title2.weight(.semibold))
            Text("MacMTP \(updater.currentVersion) · Apple Silicon")
                .font(.subheadline).foregroundStyle(.secondary)
            Group {
                switch updater.phase {
                case .checking:
                    ProgressView("Checking GitHub Releases…")
                case .available:
                    Text("Version \(updater.newVersion) is ready to install.")
                    if !updater.releaseNotes.isEmpty {
                        ScrollView {
                            Text(updater.releaseNotes).frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .frame(maxHeight: 155)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("MacMTP will download the update, quit, and reopen automatically.")
                        .foregroundStyle(.secondary)
                    if updater.blockedByTransfer {
                        Text("Finish your current file transfer to install.").foregroundStyle(.orange)
                    }
                    Button("Install & Relaunch") { updater.install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.blockedByTransfer)
                        .keyboardShortcut(.defaultAction)
                case .downloading:
                    ProgressView(value: updater.progress) {
                        Text("Downloading update…")
                    } currentValueLabel: {
                        Text("\(Int(updater.progress * 100))%").monospacedDigit()
                    }
                    Button("Cancel") { updater.cancelDownload() }
                case .verifying:
                    ProgressView("Verifying the download and preparing your update…")
                case .installing:
                    ProgressView("Reopening the updated MacMTP…")
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { Task { await updater.check() } }
                case .current:
                    Text("You’re running the latest release.").foregroundStyle(.secondary)
                    checkButton
                case .idle:
                    Text("Get the latest improvements directly from GitHub.").foregroundStyle(.secondary)
                    checkButton
                }
            }
            Divider()
            HStack {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(updater.isInstalling)
                Spacer()
                Button("Done") {
                    updater.showWindow = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(updater.isInstalling)
            }
            Text("Updates are verified against GitHub’s SHA-256 digest before installation.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 470)
        .interactiveDismissDisabled(updater.isInstalling)
    }

    private var checkButton: some View {
        Button("Check for Updates") { Task { await updater.check() } }
    }

    private var title: String {
        switch updater.phase {
        case .available: "A new MacMTP is available"
        case .current: "MacMTP is up to date"
        case .failed: "Update couldn’t be completed"
        default: "Software Update"
        }
    }
}
