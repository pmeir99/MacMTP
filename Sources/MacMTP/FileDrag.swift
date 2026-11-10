import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder supplies the destination only after the user drops the promise.
private final class ExportPromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let entry: Entry
    private let export: (Entry, URL) async throws -> Void

    init(entry: Entry, export: @escaping (Entry, URL) async throws -> Void) {
        self.entry = entry
        self.export = export
        super.init()
        fileType = entry.folder ? UTType.folder.identifier :
            (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data).identifier
        delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let name = entry.name
        return name.isEmpty || name == "." || name == ".." || name.contains("/") || name.utf8.contains(0)
            ? "Android item" : name
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        Task {
            do {
                try await export(entry, url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

struct FileDrag: NSViewRepresentable {
    let symbol: String
    let title: String
    let click: (NSEvent) -> Void
    let entries: () -> [Entry]
    let export: (Entry, URL) async throws -> Void

    func makeNSView(context: Context) -> Source { Source() }

    func updateNSView(_ view: Source, context: Context) {
        view.configuration = self
        view.toolTip = title
    }

    final class Source: NSView, NSDraggingSource {
        var configuration: FileDrag?
        private var origin: NSPoint?

        override func mouseDown(with event: NSEvent) { origin = event.locationInWindow }

        override func mouseUp(with event: NSEvent) {
            guard origin != nil else { return }
            origin = nil
            configuration?.click(event)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin, let configuration,
                  hypot(origin.x - event.locationInWindow.x, origin.y - event.locationInWindow.y) >= 5 else { return }
            let location = convert(event.locationInWindow, from: nil)
            let icon = NSImage(systemSymbolName: configuration.symbol, accessibilityDescription: nil) ?? NSImage()
            let items = configuration.entries().map { entry in
                let promise = ExportPromise(entry: entry, export: configuration.export)
                let drag = NSDraggingItem(pasteboardWriter: promise)
                drag.setDraggingFrame(NSRect(x: location.x - 20, y: location.y - 20, width: 40, height: 40), contents: icon)
                return drag
            }
            guard !items.isEmpty else { return }
            self.origin = nil
            beginDraggingSession(with: items, event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }
    }
}
