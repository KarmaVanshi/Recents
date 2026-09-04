import Foundation
@testable import Recents

// MARK: - Item builders

/// A document card, with only the fields a given test cares about set.
///
/// Paths are deliberately under a directory that does not exist, so
/// `displayName` falls through to the last path component instead of asking the
/// file system for a localized name — which would make the assertion depend on
/// whether the machine running the tests happens to have such a file.
func makeDocument(
    _ path: String,
    rank: Int = 0,
    lastUsed: Date? = nil,
    owningApp: URL? = nil,
    origin: RecentItem.Origin = .sharedFileList,
    isPinned: Bool = false
) -> RecentItem {
    var item = RecentItem(
        url: URL(fileURLWithPath: path),
        rank: rank,
        lastUsed: lastUsed,
        owningApp: owningApp,
        origin: origin
    )
    item.kind = .document
    item.isPinned = isPinned
    return item
}

func makeApplication(
    _ path: String,
    rank: Int = 0,
    lastUsed: Date? = nil,
    origin: RecentItem.Origin = .sharedFileList,
    isPinned: Bool = false
) -> RecentItem {
    let url = URL(fileURLWithPath: path)
    var item = RecentItem(
        url: url, rank: rank, lastUsed: lastUsed, owningApp: url, origin: origin
    )
    item.kind = .application
    item.isPinned = isPinned
    return item
}

func makeServer(_ absoluteString: String, rank: Int = 0) -> RecentItem {
    var item = RecentItem(
        url: URL(string: absoluteString)!, rank: rank, lastUsed: nil,
        owningApp: nil, origin: .sharedFileList
    )
    item.kind = .server
    return item
}

// MARK: - Scratch directories

/// A directory that exists for the life of one test and is removed with it.
///
/// Every reader in this app is a file reader, so almost every test needs
/// somewhere to put a file. Using the real locations would mean tests that read
/// whatever the machine happens to hold and, worse, tests that write to the
/// user's own pins and preferences.
final class ScratchDirectory {

    let url: URL

    init() {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RecentsTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func writeFile(_ name: String, contents: String = "x") -> URL {
        let file = url.appendingPathComponent(name)
        try? contents.data(using: .utf8)?.write(to: file)
        return file
    }

    @discardableResult
    func makeSubdirectory(_ name: String) -> URL {
        let directory = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func url(for name: String) -> URL { url.appendingPathComponent(name) }
}

// MARK: - Shared file lists

/// Writes a `.sfl4`-shaped archive: a keyed archive of `["items": [...]]`, where
/// each item carries a `Bookmark` blob. This is the exact shape
/// `SharedFileListReader` documents and decodes.
func writeSharedFileList(_ urls: [URL], to destination: URL) throws {
    let items: [[String: Any]] = try urls.map { url in
        ["Bookmark": try url.bookmarkData(), "Name": url.lastPathComponent]
    }
    let data = try NSKeyedArchiver.archivedData(
        withRootObject: ["items": items], requiringSecureCoding: false
    )
    try data.write(to: destination)
}

// MARK: - Office bookmark stores

/// Writes an Office `securebookmarks.plist`: a dictionary keyed by
/// percent-encoded `file://` URL strings, each value carrying a last-used date.
func writeOfficeStore(_ entries: [(url: URL, lastUsed: Date)], to destination: URL) throws {
    var root: [String: Any] = [:]
    for entry in entries {
        root[entry.url.absoluteString] = [
            "kLastUsedDateKey": entry.lastUsed,
            "kUUIDKey": UUID().uuidString,
        ]
    }
    let data = try PropertyListSerialization.data(
        fromPropertyList: root, format: .binary, options: 0
    )
    try data.write(to: destination)
}
