import AppKit
import UniformTypeIdentifiers

extension Entry {
    var contentType: UTType? { folder ? .folder : UTType(filenameExtension: (name as NSString).pathExtension) }
    var kind: String {
        if folder { return "Folder" }
        if let description = contentType?.localizedDescription { return description }
        let suffix = (name as NSString).pathExtension.uppercased()
        return suffix.isEmpty ? "Document" : "\(suffix) document"
    }
    var symbol: String {
        guard !folder else { return "folder.fill" }
        guard let type = contentType else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// Keyboard destinations are computed from the same sorted, filtered items drawn on screen.
enum FileNavigation {
    static func destination(ids: [UInt32], selected: UInt32?, delta: Int) -> UInt32? {
        guard !ids.isEmpty else { return nil }
        guard let selected, let index = ids.firstIndex(of: selected) else {
            return delta < 0 ? ids.last : ids.first
        }
        return ids[min(max(0, index + delta), ids.count - 1)]
    }
}
