import Foundation

/// MTP has no atomic replace. Stage the new data first, then preserve the old
/// object under a recoverable name until publishing the new object succeeds.
public enum FinderReplacement {
    public static func commit(staged: UInt32, original: UInt32?, name: String,
                              rename: (UInt32, String) throws -> Void,
                              remove: (UInt32) throws -> Void) throws {
        var published = false
        defer { if !published { try? remove(staged) } }
        guard let original else { try rename(staged, name); published = true; return }
        let backup = ".macmtp-backup-\(UUID().uuidString)"
        try rename(original, backup)
        do { try rename(staged, name); published = true }
        catch let publishError {
            do { try rename(original, name) }
            catch { throw DAVError(503, "Replacement failed. The original is preserved as \(backup). Reconnect before retrying.") }
            throw publishError
        }
        do { try remove(original) }
        catch { throw DAVError(503, "The new file was saved, but the original backup \(backup) could not be removed. Refresh before retrying.") }
    }
}
