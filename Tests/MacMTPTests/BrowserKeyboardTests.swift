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
                application.sendEvent(event)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(selected, [expected], "\(layout): native keyboard event must update selection")
            }
            window.close()
        }
    }
}

extension BrowserKeyboardTests {
    @MainActor
    func testColumnArrowsTraverseHierarchyAndReturnToSibling() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let first = Entry(id: 10, name: "Camera", folder: true, size: 0, modified: nil)
        let sibling = Entry(id: 20, name: "Downloads", folder: true, size: 0, modified: nil)
        let nested = Entry(id: 11, name: "Photos", folder: true, size: 0, modified: nil)
        let leaf = Entry(id: 12, name: "image.jpg", folder: false, size: 1, modified: nil)
        var selected = Set<UInt32>()
        let browser = Browser(testEntries: [first, sibling], directories: [10: [nested], 11: [leaf], 20: []],
                              layout: "Columns") { selected = $0 }.environmentObject(AppUpdater())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: browser)
        window.makeKeyAndOrderFront(nil)
        application.activate()
        try await Task.sleep(for: .milliseconds(350))
        let keys: [(UInt16, UInt32)] = [(125, 10), (124, 11), (124, 12), (123, 11), (123, 10), (125, 20)]
        for (code, expected) in keys {
            let characters = String(UnicodeScalar(0xF700 + (code == 125 ? 1 : code == 123 ? 2 : 3))!)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            application.sendEvent(event)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(selected, [expected], "Column navigation must retain the active column and hierarchy")
        }
    }
}

extension BrowserKeyboardTests {
    @MainActor
    func testFileCommandsDoNotCaptureOtherControls() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let entry = Entry(id: 1, name: "file.txt", folder: false, size: 1, modified: nil)
        var selection = Set<UInt32>()
        let browser = Browser(testEntries: [entry], layout: "List") { selection = $0 }.environmentObject(AppUpdater())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 650))
        let host = NSHostingView(rootView: browser)
        host.frame = NSRect(x: 200, y: 0, width: 900, height: 650)
        let other = OtherControl(frame: NSRect(x: 0, y: 0, width: 180, height: 650))
        container.addSubview(host)
        container.addSubview(other)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        application.activate()
        try await Task.sleep(for: .milliseconds(350))
        window.makeFirstResponder(other)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        application.sendEvent(event)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(other.received, 1)
        XCTAssertTrue(selection.isEmpty, "Sidebar and other controls must retain their own keyboard behavior.")
    }

    private final class OtherControl: NSView {
        var received = 0
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { received += 1 }
    }
}
