import AppKit
import SwiftUI

/// Native field editor preserves Finder's Return-to-commit, Escape-to-cancel behavior.
struct InlineFileName: NSViewRepresentable {
    let name: String
    let completion: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: name)
        field.isBordered = true
        field.focusRingType = .default
        field.delegate = context.coordinator
        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeFirstResponder(field)
            if let editor = field.currentEditor() {
                let suffix = (name as NSString).pathExtension
                let length = (name as NSString).length - (suffix.isEmpty ? 0 : (suffix as NSString).length + 1)
                editor.selectedRange = NSRange(location: 0, length: max(0, length))
            }
        }
        return field
    }
    func updateNSView(_ view: NSTextField, context: Context) {}

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
                guard !value.isEmpty, value != ".", value != "..", !value.contains("/"),
                      !value.utf8.contains(0), value.utf16.count < 255 else { NSSound.beep(); return true }
                finish(value)
                return true
            }
            return false
        }
        func controlTextDidEndEditing(_ notification: Notification) { finish(nil) }
    }
}
