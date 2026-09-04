import Foundation

/// Reads macOS's own "Recent Items" data — the exact lists the Apple menu shows.
///
/// Format notes (verified on macOS 26.5, which uses `.sfl4`; most references
/// online describe `.sfl3` or `.sfl2`):
///
///   NSKeyedArchiver plist
///     └─ root dict
///          ├─ "items"      → [[String: Any]]   ← array order IS recency order
///          │     └─ each: "Bookmark" (Data), "uuid", "Name"?, "visibility"
///          └─ "properties"
///
/// The `Bookmark` blobs are standard `book`-magic bookmark data and resolve with
/// `URL(resolvingBookmarkData:)`.
enum SharedFileListReader {

    /// Which system list to read.
    enum List {
        case recentDocuments
        case recentApplications
        case recentServers
        /// Per-application recent documents, keyed by bundle identifier.
        case appDocuments(bundleID: String)

        var relativePath: String {
            switch self {
            case .recentDocuments:
                return "com.apple.LSSharedFileList.RecentDocuments.sfl4"
            case .recentApplications:
                return "com.apple.LSSharedFileList.RecentApplications.sfl4"
            case .recentServers:
                return "com.apple.LSSharedFileList.RecentServers.sfl4"
            case .appDocuments(let bundleID):
                return "com.apple.LSSharedFileList.ApplicationRecentDocuments/\(bundleID).sfl4"
            }
        }
    }

    static var containerURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
    }

    static func url(for list: List) -> URL {
        containerURL.appendingPathComponent(list.relativePath)
    }

    /// Distinguishes "no permission" from "genuinely empty" so the UI can show
    /// the Full Disk Access banner only when it is actually the problem.
    enum ReadResult {
        case ok([URL])
        /// The file exists but we could not read it — almost always TCC.
        case denied
        /// No such list on this machine; not an error.
        case missing
    }

    static func read(_ list: List) -> ReadResult {
        read(at: url(for: list))
    }

    /// The decode, separated from where the file happens to live.
    ///
    /// Exposed so the three-way `.ok`/`.denied`/`.missing` verdict — which is
    /// what decides whether the deck shows a Full Disk Access banner — can be
    /// tested against real archives written to a scratch directory, rather than
    /// against whatever is in the user's own home folder.
    static func read(at fileURL: URL) -> ReadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // A file that exists but refuses to open is the TCC signature.
            return .denied
        }

        guard let items = decodeItems(from: data) else { return .ok([]) }

        var urls: [URL] = []
        urls.reserveCapacity(items.count)
        for item in items {
            guard let bookmark = item["Bookmark"] as? Data else { continue }
            guard let resolved = resolve(bookmark: bookmark) else { continue }
            urls.append(resolved)
        }
        return .ok(urls)
    }

    /// Convenience for callers that do not care why a list was empty.
    static func urls(for list: List) -> [URL] {
        if case .ok(let urls) = read(list) { return urls }
        return []
    }

    private static func decodeItems(from data: Data) -> [[String: Any]]? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        // These archives contain plain Foundation containers written by
        // sharedfilelistd; secure coding would reject them.
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }

        let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? [String: Any]
        return root?["items"] as? [[String: Any]]
    }

    private static func resolve(bookmark: Data) -> URL? {
        var isStale = false
        // .withoutUI and .withoutMounting matter: without them a stale bookmark
        // to a network volume will block trying to mount it, and can throw up
        // an authentication dialog from a background refresh.
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// Where the per-application recent-documents lists live.
    ///
    /// Exposed because `RecentsStore` watches this directory: `sharedfilelistd`
    /// renames a replacement list into place on every change, which is a write
    /// to the directory, and that is what lets the expensive ownership map be
    /// invalidated on change rather than on a clock.
    static var appDocumentsDirectory: URL {
        containerURL.appendingPathComponent(
            "com.apple.LSSharedFileList.ApplicationRecentDocuments", isDirectory: true)
    }

    /// Reads one app's own recent-documents list, tolerating filename case.
    ///
    /// `sharedfilelistd` writes these files in whatever case it feels like —
    /// Preview's is `com.apple.preview.sfl4` while the app itself reports
    /// `com.apple.Preview` — so a direct read built from `Bundle.bundleIdentifier`
    /// only works because the boot volume happens to be case-insensitive. The
    /// main deck's documents now come from exactly one of these lists, so that
    /// coincidence is no longer an acceptable thing to depend on: resolve the
    /// real filename from the directory first, and only fall back to the
    /// spelling we were given when nothing matches.
    static func readAppDocuments(bundleID: String) -> ReadResult {
        let wanted = bundleID.lowercased()
        let actual = appsWithDocumentLists().first { $0.lowercased() == wanted } ?? bundleID
        return read(.appDocuments(bundleID: actual))
    }

    /// Every bundle identifier that has a per-app recent-documents list.
    /// Verified: 63 of these on a normal machine.
    static func appsWithDocumentLists() -> [String] {
        let dir = appDocumentsDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".sfl4") }
            .map { String($0.dropLast(".sfl4".count)) }
    }

    /// Maps each recently-used document to the app whose list it appears in.
    ///
    /// This is better attribution than LaunchServices' default-app lookup,
    /// because it reflects what actually opened the file rather than what
    /// *would* open it. Note that Microsoft Office apps contribute nothing here
    /// — their `.sfl4` files exist but are empty, because Office keeps its MRU
    /// privately; `OfficeRecentsReader` is what reads that, and `RecentsStore`
    /// merges the two.
    static func documentOwners() -> [URL: String] {
        documentIndex().owners
    }

    /// Both directions of the per-app lists, read in one pass.
    ///
    /// `owners` answers "which app opened this document", for the icon that
    /// badges a document card. `documentsByApp` answers the opposite — "what has
    /// this app been opening" — which is what an application card expands into.
    ///
    /// They come from the same read deliberately. Building the ownership map
    /// already opens and bookmark-resolves all ~60 lists, and simply threw the
    /// grouping away; keeping it costs one dictionary and no extra file I/O on
    /// what is the single most expensive read in the app.
    struct DocumentIndex {
        var owners: [URL: String] = [:]
        var documentsByApp: [String: [URL]] = [:]

        /// Folds a second source in behind this one.
        ///
        /// Precedence is one-directional and deliberate: whatever is already
        /// here wins. `RecentsStore` merges Office's private lists into the
        /// shared ones this way round, so a document macOS has attributed keeps
        /// that attribution, and Office only ever fills gaps — the apps whose
        /// shared list is empty, which on any real machine is all three of them.
        mutating func merge(_ other: DocumentIndex) {
            for (bundleID, urls) in other.documentsByApp {
                guard var existing = documentsByApp[bundleID] else {
                    documentsByApp[bundleID] = urls
                    continue
                }
                var seen = Set(existing)
                existing.append(contentsOf: urls.filter { seen.insert($0).inserted })
                documentsByApp[bundleID] = existing
            }
            for (url, bundleID) in other.owners where owners[url] == nil {
                owners[url] = bundleID
            }
        }
    }

    static func documentIndex() -> DocumentIndex {
        var index = DocumentIndex()

        for bundleID in appsWithDocumentLists() {
            let urls = urls(for: .appDocuments(bundleID: bundleID))
            guard !urls.isEmpty else { continue }

            // Keyed lowercase throughout. These filenames are whatever case
            // `sharedfilelistd` wrote — `com.microsoft.vscode.sfl4` — while
            // `Bundle.bundleIdentifier` reports the app's own spelling,
            // `com.microsoft.VSCode`. Reading the file survives that because the
            // volume is normally case-insensitive; a dictionary lookup does not.
            index.documentsByApp[bundleID.lowercased()] = urls

            for url in urls where index.owners[url] == nil {
                index.owners[url] = bundleID
            }
        }

        return index
    }
}
