import AppKit
import ImageIO
import QuickLookThumbnailing

/// One cache per connection. Metadata and handles never cross device sessions.
@MainActor
final class PreviewStore: ObservableObject {
    var suspended = false
    private var fetching = false
    private let images = NSCache<NSString, NSImage>()
    private var unavailable = Set<String>()
    private var directory: URL?
    private var localKey: String?
    private var localURL: URL?
    @Published private(set) var generation = UUID()

    init() {
        images.totalCostLimit = 48 * 1024 * 1024
        images.countLimit = 256
    }

    deinit {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func reset() {
        generation = UUID()
        images.removeAllObjects()
        unavailable.removeAll()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        localKey = nil
        localURL = nil
    }

    private func key(_ entry: Entry, storage: UInt32) -> String {
        "\(storage)-\(entry.id)-\(entry.size)-\(entry.modified?.timeIntervalSince1970 ?? 0)-\(entry.name)"
    }

    func image(_ entry: Entry, storage: UInt32, device: Device) async -> NSImage? {
        let key = key(entry, storage: storage)
        if let image = images.object(forKey: key as NSString) { return image }
        guard !entry.folder, !unavailable.contains(key) else { return nil }
        let revision = generation
        do {
            // Give selection and folder listing priority over speculative preview traffic.
            try await Task.sleep(for: .milliseconds(180))
            while fetching || suspended {
                try await Task.sleep(for: .milliseconds(50))
                guard generation == revision else { return nil }
            }
            try Task.checkCancellation()
            if let image = images.object(forKey: key as NSString) { return image }
            guard !unavailable.contains(key), generation == revision else { return nil }
            fetching = true
            defer { fetching = false }
            let data = try await device.thumbnail(entry)
            try Task.checkCancellation()
            guard generation == revision else { return nil }
            var image: NSImage?
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720
               ] as CFDictionary) {
                image = NSImage(cgImage: cg, size: .zero)
            } else if !data.isEmpty {
                let url = try workspace().appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension((entry.name as NSString).pathExtension)
                defer { try? FileManager.default.removeItem(at: url) }
                try data.write(to: url, options: .atomic)
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 720, height: 720),
                                                           scale: 1, representationTypes: .thumbnail)
                image = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            }
            try Task.checkCancellation()
            guard generation == revision else { return nil }
            if let image { images.setObject(image, forKey: key as NSString, cost: 720 * 720 * 4) }
            else {
                if unavailable.count >= 512 { unavailable.removeAll() }
                unavailable.insert(key)
            }
            return image
        } catch is CancellationError { return nil }
        catch {
            // A transient USB failure must not permanently poison the cache.
            return nil
        }
    }

    func localFile(_ entry: Entry, storage: UInt32, device: Device,
                   progress: @escaping @Sendable (TransferEvent) -> Void) async throws -> URL {
        guard !entry.folder, !entry.name.isEmpty, entry.name != ".", entry.name != "..",
              !entry.name.contains("/"), !entry.name.utf8.contains(0) else { throw DeviceError.unsafeName }
        if let cached = cachedFile(entry, storage: storage) { return cached }
        clearLocalFiles()
        let revision = generation
        let folder = try workspace().appendingPathComponent("QuickLook", isDirectory: true)
            .appendingPathComponent("\(storage)-\(entry.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let target = folder.appendingPathComponent(entry.name)
        if !FileManager.default.fileExists(atPath: target.path) {
            try await device.download(entry, storage: storage, into: folder, progress: progress)
        }
        try Task.checkCancellation()
        guard revision == generation else { throw DeviceError.unavailable }
        localKey = key(entry, storage: storage)
        localURL = target
        return target
    }

    func cachedFile(_ entry: Entry, storage: UInt32) -> URL? {
        guard localKey == key(entry, storage: storage), let localURL,
              FileManager.default.fileExists(atPath: localURL.path) else { return nil }
        return localURL
    }

    private func clearLocalFiles() {
        localKey = nil
        localURL = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("QuickLook", isDirectory: true))
        }
    }

    private func workspace() throws -> URL {
        if let directory { return directory }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacMTP-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        directory = url
        return url
    }
}
