import Foundation

/// Validate the central directory and matching local filenames before extraction.
/// The app package contains regular files and directories, never symbolic links.
public enum UpdateArchive {
    public static func validate(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else { throw UpdateError.invalidArchive }
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, count <= data.count - offset else { throw UpdateError.invalidArchive }
            return (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        let lower = max(0, data.count - 65_557)
        guard let end = stride(from: data.count - 22, through: lower, by: -1).first(where: {
            (try? number($0, 4)) == 0x06054b50 &&
            (try? number($0 + 20, 2)) == data.count - $0 - 22
        }) else { throw UpdateError.invalidArchive }
        let count = try number(end + 10, 2)
        let centralSize = try number(end + 12, 4)
        let centralStart = try number(end + 16, 4)
        guard try number(end + 4, 2) == 0, try number(end + 6, 2) == 0,
              try number(end + 8, 2) == count, count > 0, count < 20_000,
              centralStart + centralSize == end else { throw UpdateError.invalidArchive }
        var cursor = centralStart
        var expanded: UInt64 = 0
        var names = Set<String>()
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x02014b50 else { throw UpdateError.invalidArchive }
            let flags = try number(cursor + 8, 2)
            let method = try number(cursor + 10, 2)
            let compressed = try number(cursor + 20, 4)
            let size = try number(cursor + 24, 4)
            let length = try number(cursor + 28, 2)
            let extra = try number(cursor + 30, 2)
            let comment = try number(cursor + 32, 2)
            let mode = try number(cursor + 38, 4) >> 16
            let local = try number(cursor + 42, 4)
            let nameStart = cursor + 46
            guard length > 0, nameStart + length <= end,
                  let name = String(data: data[nameStart..<(nameStart + length)], encoding: .utf8),
                  !name.contains("\\"), !name.utf8.contains(0), !name.hasPrefix("/"),
                  !name.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  name == "MacMTP.app/" || name.hasPrefix("MacMTP.app/") || name.hasPrefix("__MACOSX/"),
                  names.insert(name).inserted, flags & 1 == 0, method == 0 || method == 8,
                  [0, 0o040000, 0o100000].contains(mode & 0o170000),
                  try number(cursor + 34, 2) == 0,
                  try number(local, 4) == 0x04034b50,
                  try number(local + 26, 2) == length else { throw UpdateError.invalidArchive }
            let localExtra = try number(local + 28, 2)
            let localStart = local + 30
            guard localStart + length <= centralStart,
                  data[localStart..<(localStart + length)] == data[nameStart..<(nameStart + length)],
                  localStart + length + localExtra + compressed <= centralStart else {
                throw UpdateError.invalidArchive
            }
            expanded += UInt64(size)
            guard expanded <= 1024 * 1024 * 1024 else { throw UpdateError.invalidArchive }
            cursor = nameStart + length + extra + comment
            guard cursor <= end else { throw UpdateError.invalidArchive }
        }
        guard cursor == end, names.contains("MacMTP.app/Contents/Info.plist"),
              names.contains("MacMTP.app/Contents/MacOS/MacMTP") else { throw UpdateError.invalidArchive }
    }
}
