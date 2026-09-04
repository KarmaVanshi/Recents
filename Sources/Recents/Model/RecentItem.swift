import AppKit
import Foundation

/// One entry in the deck: a file the user touched recently, plus everything we
/// know about how and when they touched it.
///
/// Identity is the resolved file URL — that is the key both data sources agree
/// on, and the key the merge in `RecentsStore` dedupes by.
struct RecentItem: Identifiable, Hashable {

    /// Where the item came from. Kept so the UI can explain itself and so the
    /// merge can prefer the authoritative source's ordering.
    enum Origin: Hashable {
        /// The Apple menu's own list. Carries true recency order, no timestamp.
        case sharedFileList
        /// Spotlight metadata. Carries a real timestamp, weaker ordering.
        case spotlight
        /// Seen in both — the best case.
        case both
        /// Running right now, but macOS has not yet written it to its recent
        /// applications list. Not in the Apple menu, but not a guess either.
        case runningApplication
    }

    /// Applications and documents are both "recent items", but they are shown
    /// very differently: an app card is a landscape window screenshot, a
    /// document card is a portrait page preview.
    enum Kind: Hashable {
        case application
        case document
        /// A network volume from `RecentServers.sfl4` — the Apple menu lists
        /// these alongside documents, and its URL is `smb://…`, not a file path.
        case server
    }

    let url: URL

    var kind: Kind = .document

    /// Rank from the shared file list, if present. Lower is more recent.
    /// Spotlight-only items get a rank past the end of the shared list.
    var rank: Int

    /// `kMDItemLastUsedDate` when Spotlight knew it. Nil for shared-list-only
    /// items, which is why the UI must tolerate a missing timestamp.
    var lastUsed: Date?

    /// Bundle URL of the app that owns this document, resolved either from the
    /// per-app shared lists or from LaunchServices.
    var owningApp: URL?

    var origin: Origin

    var isPinned: Bool = false

    var id: URL { url }

    var displayName: String {
        // A server URL has no file-system name to localize, and its last path
        // component is a share name that means nothing on its own.
        if kind == .server {
            let share = url.lastPathComponent
            guard let host = url.host else { return url.absoluteString }
            return share.isEmpty || share == "/" ? host : "\(share) — \(host)"
        }
        // Prefer the localized name — this is what Finder shows, and it strips
        // extensions when the user has that preference set.
        return (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? url.lastPathComponent
    }

    var appName: String? {
        guard let owningApp else { return nil }
        return (try? owningApp.resourceValues(forKeys: [.localizedNameKey]).localizedName)
            ?? owningApp.deletingPathExtension().lastPathComponent
    }

    /// Bundle identifier, for applications. Used to look up the captured
    /// window screenshot in `AppWindowCapture`.
    var bundleID: String? {
        guard kind == .application else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// True when macOS's own Recent Items list vouches for this entry — which is
    /// also what makes its position in the deck the Apple menu's position rather
    /// than one we inferred.
    var isAppleMenuAuthoritative: Bool {
        switch origin {
        case .sharedFileList, .both: return true
        case .spotlight, .runningApplication: return false
        }
    }

    var isDirectory: Bool {
        guard url.isFileURL else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// True when the file no longer exists. Recents lists go stale constantly —
    /// items get moved, renamed, or deleted — so the deck filters these out.
    ///
    /// A server is exempt: an unmounted share is the normal state for one, and
    /// reaching out to check would mean a blocking network round trip on every
    /// refresh.
    var stillExists: Bool {
        guard url.isFileURL else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func == (a: RecentItem, b: RecentItem) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }

    /// Whether two entries agree on everything a card draws, not merely on which
    /// file they name.
    ///
    /// `==` is deliberately identity — the resolved URL — because that is what
    /// the merge dedupes by and what `ForEach` keys on. Asking whether a *list*
    /// has gone stale is a different question, and answering it with `==` gets
    /// it wrong: pinning the item that is already at the front produces a list
    /// equal to the old one in every URL and equal in order, so a cache keyed on
    /// `==` hands back the pre-pin values and the card keeps drawing an unpinned
    /// pin. Timestamps go stale the same way while a filter is up.
    func hasSameContent(as other: RecentItem) -> Bool {
        url == other.url
            && kind == other.kind
            && rank == other.rank
            && lastUsed == other.lastUsed
            && owningApp == other.owningApp
            && origin == other.origin
            && isPinned == other.isPinned
    }
}

extension Array where Element == RecentItem {
    /// Element-wise `hasSameContent`, for deciding whether a derived list needs
    /// recomputing.
    func hasSameContent(as other: [RecentItem]) -> Bool {
        count == other.count && zip(self, other).allSatisfy { $0.hasSameContent(as: $1) }
    }
}

extension RecentItem {
    /// Short human phrasing for the card subtitle: "Preview · 2h ago".
    var subtitle: String {
        if kind == .server {
            return "Server · \(url.scheme?.uppercased() ?? "Network")"
        }
        if kind == .application {
            guard let lastUsed else { return "Application" }
            return "Application · " + RelativeDateTimeFormatter.shared
                .localizedString(for: lastUsed, relativeTo: Date())
        }
        let app = appName
        guard let lastUsed else { return app ?? "" }
        let rel = RelativeDateTimeFormatter.shared.localizedString(for: lastUsed, relativeTo: Date())
        return [app, rel].compactMap { $0 }.joined(separator: " · ")
    }
}

extension RelativeDateTimeFormatter {
    static let shared: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
