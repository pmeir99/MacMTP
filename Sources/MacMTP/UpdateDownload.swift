import Foundation

final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var saved: URL?
    private var failure: Error?

    init(destination: URL, size: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        expectedSize = size
        self.progress = progress
    }

    func download(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                guard !cancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 600
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let hosts: Set<String> = ["github.com", "release-assets.githubusercontent.com",
                                   "objects.githubusercontent.com", "github-releases.githubusercontent.com"]
        guard let url = request.url, url.scheme == "https", hosts.contains(url.host ?? ""),
              url.user == nil, url.password == nil else {
            failure = UpdateError.invalidRelease
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expectedSize else {
            failure = UpdateError.invalidArchive
            downloadTask.cancel()
            return
        }
        progress(Double(totalBytesWritten) / Double(expectedSize))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
                  Int64((try location.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? -1) == expectedSize else {
                throw UpdateError.invalidArchive
            }
            try FileManager.default.moveItem(at: location, to: destination)
            saved = destination
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()
        if let failure = failure ?? error { continuation?.resume(throwing: failure) }
        else if let saved { continuation?.resume(returning: saved) }
        else { continuation?.resume(throwing: UpdateError.invalidArchive) }
        session.finishTasksAndInvalidate()
    }
}
