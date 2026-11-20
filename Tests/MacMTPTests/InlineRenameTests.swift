import AppKit
import SwiftUI
import XCTest
@testable import MacMTP

final class InlineRenameTests: XCTestCase {
    @MainActor
    func testReturnEditsNameAndEscapeRestoresArrowNavigation() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let entries = ["report.txt", "second.txt"].enumerated().map {
            Entry(id: UInt32($0.offset + 1), name: $0.element, folder: false, size: 1, modified: nil)
        }
        var selection = Set<UInt32>()
        let browser = Browser(testEntries: entries, layout: "List") { selection = $0 }.environmentObject(AppUpdater())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: browser)
        window.makeKeyAndOrderFront(nil)
        application.activate()
        try await Task.sleep(for: .milliseconds(350))
        func key(_ code: UInt16, _ characters: String) throws {
            application.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
        }
        try key(125, "\u{F701}")
        try await Task.sleep(for: .milliseconds(150))
        try key(36, "\r")
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(window.firstResponder is NSTextView), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "Inline editor must receive focus; responder was \(String(describing: window.firstResponder))")
        XCTAssertEqual(editor.string, "report.txt")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 6), "Preserve the file extension while editing.")
        try key(123, "\u{F702}")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(selection, [1], "Arrow keys in the name editor must edit text, not change file selection.")
        try key(53, "\u{1b}")
        try await Task.sleep(for: .milliseconds(250))
        try key(125, "\u{F701}")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(selection, [2], "Canceling rename must restore file navigation focus.")
    }
}
