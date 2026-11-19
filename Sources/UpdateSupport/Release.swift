import Foundation
import CryptoKit
import Darwin

public enum UpdateError: LocalizedError {
    case invalidRelease, invalidArchive, invalidApplication, checksumMismatch
    case permission, tool(String), timeout

    public var errorDescription: String? {
        switch self {
        case .invalidRelease: "GitHub did not provide a valid MacMTP update. Try again later."
        case .invalidArchive: "The downloaded archive is invalid. Your installed app has not been changed."
        case .invalidApplication: "The downloaded app did not pass verification. Your installed app has not been changed."
        case .checksumMismatch: "The download did not match GitHub’s SHA-256 digest. Try downloading again."
        case .permission: "Move MacMTP to a writable Applications folder before installing an update."
        case .tool(let detail): detail
        case .timeout: "The update could not finish. Your previous MacMTP version has been preserved."
        }
    }
}

public struct AppVersion: Comparable, Equatable, Sendable {
    public let value: String
    private let parts: [Int]

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              parts.allSatisfy({ $0.count == 1 || $0.first != "0" }) else { return nil }
        self.parts = [major, minor, patch]
        value = string
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }
}

public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int64
        public let digest: String?
        public let browser_download_url: URL
    }

    public let tag_name: String
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    public func update(after installed: AppVersion) throws -> (AppVersion, Asset)? {
        guard !draft, !prerelease, tag_name.hasPrefix("v"),
              let version = AppVersion(String(tag_name.dropFirst())) else { throw UpdateError.invalidRelease }
        guard version > installed else { return nil }
        guard let asset = assets.first(where: { $0.name == "MacMTP.zip" }),
              asset.size > 0, asset.size <= 512 * 1024 * 1024,
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              digest.count == 71, digest.dropFirst(7).allSatisfy({ $0.isHexDigit }),
              asset.browser_download_url.scheme == "https",
              asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path == "/pmeir99/MacMTP/releases/download/\(tag_name)/MacMTP.zip",
              asset.browser_download_url.user == nil, asset.browser_download_url.password == nil,
              asset.browser_download_url.query == nil else { throw UpdateError.invalidRelease }
        return (version, asset)
    }
}

public enum UpdateFiles {
    public static let identifier = "com.meir.macmtp"

    public static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(identifier).appendingPathComponent("Updates", isDirectory: true)
    }

    public static func workspace(_ token: UUID) -> URL {
        root.appendingPathComponent(token.uuidString, isDirectory: true)
    }

    public static func checksum(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            hash.update(data: bytes)
        }
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public static func tool(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: bytes, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw UpdateError.tool(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }

    public static func verifyApplication(_ app: URL, version: String) throws {
        let resolved = app.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved == app.standardizedFileURL, app.pathExtension == "app",
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == identifier,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "MacMTP",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == version,
              bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "27.0"
        else { throw UpdateError.invalidApplication }
        try tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let executable = app.appendingPathComponent("Contents/MacOS/MacMTP")
        let architecture = try tool("/usr/bin/lipo", ["-archs", executable.path])
        guard architecture.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64",
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/Helpers/MacMTPUpdate").path)
        else { throw UpdateError.invalidApplication }
    }

    public static func acknowledgeLaunch(arguments: [String], version: String) {
        guard let index = arguments.firstIndex(of: "--macmtp-update-token"),
              index + 1 < arguments.count, let token = UUID(uuidString: arguments[index + 1]) else { return }
        let folder = workspace(token)
        // Only acknowledge an existing private workspace created by this user.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: folder.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { return }
        try? Data(version.utf8).write(to: folder.appendingPathComponent("launched"), options: .atomic)
    }
}
