import AppKit
import SwiftUI
import QuickLookUI
import XCTest
@testable import MacMTP

final class QuickLookTests: XCTestCase {
    @MainActor
    func testSpaceOpensNativeQuickLookForSelectedFile() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MacMTP-\(UUID().uuidString).txt")
        try "Quick Look integration check".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let entry = Entry(id: 1, name: file.lastPathComponent, folder: false, size: 28, modified: nil)
        var selection = Set<UInt32>()
        var transferCounts: [Int] = []
        let browser = Browser(testEntries: [entry], previewFile: file,
                              transferCountObserver: { transferCounts.append($0) }, layout: "List") { selection = $0 }
            .environmentObject(AppUpdater())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { QLPreviewPanel.shared()?.orderOut(nil); window.close() }
        window.contentView = NSHostingView(rootView: browser)
        window.makeKeyAndOrderFront(nil)
        application.activate()
        try await Task.sleep(for: .milliseconds(350))
        for (code, characters) in [(UInt16(125), "\u{F701}"), (49, " ")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            application.sendEvent(event)
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(selection, [1])
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while QLPreviewPanel.shared()?.isVisible != true, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(QLPreviewPanel.shared()?.isVisible == true)
        XCTAssertEqual(QLPreviewPanel.shared()?.currentPreviewItem?.previewItemURL, file)
        XCTAssertFalse(transferCounts.isEmpty)
        XCTAssertTrue(transferCounts.allSatisfy { $0 == 0 }, "Preparing Quick Look must not add an upload/download progress card.")
    }
}
