import Foundation

/// Microsoft Office's private recent-documents list.
///
/// Word, Excel and PowerPoint are the conspicuous hole in the shared file
/// lists. They *do* have `ApplicationRecentDocuments/com.microsoft.word.sfl4`
/// files — so the directory listing looks complete — but every one of them is
/// empty: verified 0 items in all three, against 10 for Preview and 7 for VS
/// Code on the same machine. Office registers the file with LaunchServices (so
/// documents reach the Apple menu's combined list) and then keeps its own MRU
/// privately, which is why an app card for Word had nothing to expand into.
///
/// The private list is the sandbox's security-scoped bookmark store:
///
///   ~/Library/Containers/<bundleID>/Data/Library/Preferences/
///       <bundleID>.securebookmarks.plist
///
///     └─ root dict — keys are percent-encoded `file://` URL strings
///          └─ each value: "kBookmarkDataKey" (Data)
///                         "kUUIDKey"         (String)
///                         "kLastUsedDateKey" (Date)   ← recency order
///
/// Two things make this cheap. The dictionary *keys* are already the file URLs,
/// so the bookmark blobs never have to be resolved — no `URL(resolvingBookmark…)`
/// round trip, and no risk of one of them reaching for a network volume. And
/// `kLastUsedDateKey` is a real timestamp, so unlike an `.sfl4` list this one
/// carries its own order rather than depending on array position.
///
/// The honest caveat: this is undocumented Office internals in a sandbox
/// container, not a system API. An Office update can rename the file or change
/// the keys, and if it does, every read here simply returns nothing — no app
/// card loses its own recents, Word's card just stops offering any, exactly as
/// it behaved before this file existed. Nothing else in the deck depends on it.
enum OfficeRecentsReader {

    /// The three apps that keep their MRU this way.
    ///
    /// Spelled as the apps spell their own bundle identifiers, which is also how
    /// the container directories are named — note PowerPoint's lowercase `p`,
    /// which is Microsoft's, not a typo. Everything downstream keys on the
    /// lowercased form anyway, for the same reason `SharedFileListReader` does.
    static let bundleIDs = [
        "com.microsoft.Word",
        "com.microsoft.Excel",
        "com.microsoft.Powerpoint",
    ]

    /// One entry from the store: where the document is, and when Office last
    /// touched it.
    struct Entry {
        let url: URL
        let lastUsed: Date
    }

    /// Mirrors `SharedFileListReader.ReadResult` so the two sources fail the
    /// same way and callers can treat them alike.
    enum ReadResult {
        case ok([Entry])
        /// The container is there but the file would not open — the same TCC
        /// signature as an unreadable `.sfl4`, since `~/Library/Containers` is
        /// Full Disk Access territory too.
        case denied
        /// Office is not installed, or has never opened a document.
        case missing
    }

    static func url(forBundleID bundleID: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/\(bundleID)")
            .appendingPathComponent("Data/Library/Preferences/\(bundleID).securebookmarks.plist")
    }

    /// Every bookmark store that is actually on this machine.
    ///
    /// `RecentsStore` watches these, and watching a path that will never exist
    /// costs a retry timer for the life of the process — so an uninstalled
    /// Office contributes no watchers rather than three idle ones.
    static func existingStoreURLs() -> [URL] {
        bundleIDs
            .map(url(forBundleID:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// One app's private MRU, newest first.
    static func read(bundleID: String) -> ReadResult {
        read(at: url(forBundleID: bundleID))
    }

    /// The read, separated from where the store happens to live.
    ///
    /// Exposed so the parse below — which is reverse-engineered from
    /// undocumented Office internals and is the part most likely to be broken
    /// by an Office update — can be tested against a plist written to a scratch
    /// directory instead of against whatever Word last did on this machine.
    static func read(at fileURL: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }

        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            return .denied
        }

        return .ok(entries(fromPlist: data))
    }

    /// Turns one bookmark store into recents, newest first.
    static func entries(fromPlist data: Data) -> [Entry] {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            return []
        }

        var entries: [Entry] = []
        entries.reserveCapacity(root.count)

        for (key, value) in root {
            guard let fields = value as? [String: Any] else { continue }
            guard let lastUsed = fields["kLastUsedDateKey"] as? Date else { continue }
            // The key is the URL. `URL(string:)` rather than
            // `URL(fileURLWithPath:)` because these are percent-encoded — a
            // document with a space in its name arrives as `%20`, and treating
            // the string as a path would produce a file called "%20".
            guard let url = URL(string: key), url.isFileURL else { continue }

            // Office bookmarks the *folders* it has been granted access to as
            // well as the documents inside them — this machine's Word store
            // holds `~/Downloads` and the OneDrive root alongside 119 files.
            // Those are sandbox grants, not recents: Word's own File ▸ Recent
            // does not list them, so neither does the card. This is not the
            // `includeFolders` question, which is about editors that genuinely
            // record a project directory as the thing you opened.
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDirectory
            )
            if exists && isDirectory.boolValue { continue }

            entries.append(Entry(url: url.standardizedFileURL, lastUsed: lastUsed))
        }

        // The one real ordering signal these files carry. Unlike an `.sfl4`,
        // dictionary iteration order is meaningless, so this sort *is* the
        // recency order rather than a re-derivation of one.
        entries.sort { $0.lastUsed > $1.lastUsed }
        return entries
    }

    /// The same two-directional shape the shared file lists produce, so the two
    /// sources merge without either side knowing about the other.
    ///
    /// Deliberately not folded into `SharedFileListReader.documentIndex()`:
    /// that function's contract is "what macOS's own lists say", and this is
    /// emphatically not that. They are merged one level up, in `RecentsStore`,
    /// where the precedence between them can be stated once and read.
    static func documentIndex() -> SharedFileListReader.DocumentIndex {
        var index = SharedFileListReader.DocumentIndex()

        for bundleID in bundleIDs {
            guard case .ok(let entries) = read(bundleID: bundleID), !entries.isEmpty else {
                continue
            }

            let urls = entries.map(\.url)
            index.documentsByApp[bundleID.lowercased()] = urls
            for url in urls where index.owners[url] == nil {
                index.owners[url] = bundleID
            }
        }

        return index
    }
}
