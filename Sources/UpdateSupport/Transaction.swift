import Foundation
import Darwin

public enum UpdateTransaction {
    /// Both bundles must be on the same volume. An atomic swap always leaves
    /// either the old or the new bundle at the installed app's original path.
    public static func swap(_ installed: URL, _ replacement: URL) throws {
        guard installed.deletingLastPathComponent().standardizedFileURL.path ==
              replacement.deletingLastPathComponent().standardizedFileURL.path,
              installed.standardizedFileURL.path != replacement.standardizedFileURL.path else { throw UpdateError.permission }
        let result = installed.path.withCString { first in
            replacement.path.withCString { second in renamex_np(first, second, UInt32(RENAME_SWAP)) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
