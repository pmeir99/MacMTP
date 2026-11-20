import Foundation

/// Contents and their folder identity change together, before asynchronous USB work begins.
struct DirectoryContent {
    private(set) var requestedParent: UInt32?
    private(set) var loadedParent: UInt32?
    private(set) var entries: [Entry] = []
    private(set) var loading = false

    mutating func begin(parent: UInt32, cached: [Entry]?) {
        requestedParent = parent
        loadedParent = cached == nil ? nil : parent
        entries = cached ?? []
        loading = cached == nil
    }

    @discardableResult
    mutating func receive(_ items: [Entry], parent: UInt32) -> Bool {
        guard requestedParent == parent else { return false }
        entries = items
        loadedParent = parent
        loading = false
        return true
    }

    mutating func reset() { self = DirectoryContent() }
}
