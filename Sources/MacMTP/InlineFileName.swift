import AppKit
import SwiftUI

/// Native field editor preserves Finder's Return-to-commit, Escape-to-cancel behavior.
struct InlineFileName: NSViewRepresentable {
    let name: String
    let isFolder: Bool
    let completion: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeNSView(context: Context) -> EditorField {
        let field = EditorField(string: name)
        field.originalName = name
        field.isFolder = isFolder
        field.isBordered = true
        field.focusRingType = .default
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ view: EditorField, context: Context) {}

    final class EditorField: NSTextField {
        var originalName = ""
        var isFolder = false
        private var focusedOnce = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !focusedOnce else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.focusedOnce else { return }
                self.focusedOnce = true
                self.selectText(nil)
                if let editor = self.currentEditor() {
                    let suffix = self.isFolder ? "" : (self.originalName as NSString).pathExtension
                    let length = (self.originalName as NSString).length - (suffix.isEmpty ? 0 : (suffix as NSString).length + 1)
                    editor.selectedRange = NSRange(location: 0, length: max(0, length))
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var finished = false
        private let completion: (String?) -> Void
        init(_ completion: @escaping (String?) -> Void) { self.completion = completion }
        private func finish(_ value: String?) {
            guard !finished else { return }
            finished = true
            completion(value)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { finish(nil); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let value = textView.string
                guard valid(value) else { NSSound.beep(); return true }
                finish(value)
                return true
            }
            return false
        }
        private func valid(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." && !value.contains("/") &&
                !value.utf8.contains(0) && value.utf16.count < 255
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            let value = (notification.object as? NSTextField)?.stringValue
            finish(value.flatMap { valid($0) ? $0 : nil })
        }
    }
}

/// Bind directly inside the table cell so AppKit's reused row hosts observe editing changes.
struct FileNameCell: View {
    let entry: Entry
    @Binding var editing: Entry?
    let completion: (String?) -> Void

    var body: some View {
        if editing?.id == entry.id {
            InlineFileName(name: entry.name, isFolder: entry.folder, completion: completion)
        } else {
            Text(entry.name)
        }
    }
}

struct RenameInteraction<Content: View>: View {
    let entry: Entry
    @Binding var editing: Entry?
    let content: () -> Content

    init(entry: Entry, editing: Binding<Entry?>, @ViewBuilder content: @escaping () -> Content) {
        self.entry = entry
        _editing = editing
        self.content = content
    }

    var body: some View {
        if editing?.id != entry.id { content() }
    }
}
