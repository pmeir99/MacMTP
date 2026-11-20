import AppKit
import SwiftUI
import XCTest
@testable import MacMTP

final class BrowserKeyboardTests: XCTestCase {
    @MainActor
    func testNativeArrowSelectionAcrossAllFourViews() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let entries = ["a.txt", "b.txt", "c.txt"].enumerated().map {
            Entry(id: UInt32($0.offset + 1), name: $0.element, folder: false, size: 1, modified: nil)
        }
        for layout in ["Icons", "List", "Columns", "Gallery"] {
            var selected = Set<UInt32>()
            let browser = Browser(testEntries: entries, layout: layout) { selected = $0 }
                .environmentObject(AppUpdater())
            let host = NSHostingView(rootView: browser)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            application.activate()
            try await Task.sleep(for: .milliseconds(350))
            let keys: [(UInt16, UInt32)] = layout == "Icons"
                ? [(125, 1), (124, 2), (123, 1), (125, 3), (126, 1)]
                : [(125, 1), (125, 2), (126, 1)]
            for (code, expected) in keys {
                let characters = String(UnicodeScalar(0xF700 + (code == 126 ? 0 : code == 125 ? 1 : code == 123 ? 2 : 3))!)
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code))
                window.sendEvent(event)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(selected, [expected], "\(layout): native keyboard event must update selection")
            }
            window.close()
        }
    }
}
