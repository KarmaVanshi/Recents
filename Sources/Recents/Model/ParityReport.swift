import Foundation

/// Checks the deck against the lists it claims to mirror.
///
/// The app's central claim is that it shows macOS's own Recent Items, in macOS's
/// own order. That claim is easy to break by accident — any sort added anywhere
/// downstream of the merge will do it — and impossible to eyeball, because the
/// Apple menu and the deck cannot be photographed side by side in a build script.
/// So it is checked here instead: resolve each shared file list, resolve the deck,
/// and compare the two sequences directly.
///
/// The document cards are measured against Preview's own recents rather than the
/// global `RecentDocuments.sfl4` — see `RecentsStore.loadDocuments` — because
/// that is the list they come from. Checking them against the list they did not
/// come from would fail by design and tell us nothing, which is worse than not
/// checking them at all.
///
/// With `Preferences.showAllFiles` on they come from no single list: the rail is
/// every app's recents ordered by timestamp, which is a departure the deck makes
/// deliberately and marks as such. There is nothing to compare it to, so it is
/// reported as unchecked rather than quietly passed — the applications and
/// servers either side of it are still held to the Apple menu's order.
///
/// Run: `Recents --parity`. Exits 0 when the order matches, 1 when it does not,
/// which makes it usable as a check rather than only as something to read.
enum ParityReport {

    static func run() {
        // Unbuffered: this is a check meant to be piped into something, and a
        // block-buffered stdout loses the whole report if anything goes wrong
        // before the process exits normally.
        setvbuf(stdout, nil, _IONBF, 0)

        let store = RecentsStore()
        store.start()

        // Spotlight's first gather is asynchronous, and the deck is not final
        // until it lands. The comparison itself only looks at shared-file-list
        // items, but they are interleaved with Spotlight ones in `items`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let matched = report(store)
            store.stop()
            exit(matched ? 0 : 1)
        }
        RunLoop.main.run()
    }

    private static func report(_ store: RecentsStore) -> Bool {
        var allMatched = true

        print(bold("── Apple menu parity ──────────────────────────────────────"))
        print("")

        if store.needsFullDiskAccess {
            print("  ⚠︎ At least one shared file list refused to open (Full Disk Access).")
            print("    Where that happened the deck is Spotlight's ordering, not the")
            print("    Apple menu's, and parity cannot be established at all.")
            print("")
        }

        allMatched = check(
            result: SharedFileListReader.read(.recentApplications),
            named: "RecentApplications",
            deck: store.items.filter { $0.kind == .application }
        ) && allMatched

        if Preferences.shared.showAllFiles {
            let count = store.items.filter { $0.kind == .document }.count
            print(bold("  Documents — every app"))
            print("    \(count) cards, ordered by kMDItemLastUsedDate across every")
            print("    per-app list. No shared file list ranks another app's entries,")
            print("    so there is no Apple-menu order to check this against.")
            print("    Not checked. Turn off Settings ▸ Show ▸ All files to check it.")
            print("")
        } else {
            allMatched = check(
                result: SharedFileListReader.readAppDocuments(bundleID: "com.apple.Preview"),
                named: "ApplicationRecentDocuments/com.apple.preview",
                deck: store.items.filter { $0.kind == .document }
            ) && allMatched
        }

        allMatched = check(
            result: SharedFileListReader.read(.recentServers),
            named: "RecentServers",
            deck: store.items.filter { $0.kind == .server }
        ) && allMatched

        printDeck(store)

        print("")
        print(allMatched
              ? bold("✓ Deck order matches the lists it mirrors.")
              : bold("✗ Deck order diverges from the lists it mirrors."))
        return allMatched
    }

    /// Compares one list against the deck entries that claim to come from it.
    ///
    /// Entries the deck legitimately dropped — a file that no longer exists, one
    /// the user chose to forget, a folder while folders are hidden — are removed
    /// from the expected sequence first. What remains must appear in the deck in
    /// exactly that order.
    private static func check(
        result: SharedFileListReader.ReadResult, named name: String, deck: [RecentItem]
    ) -> Bool {
        print(bold("  \(name).sfl4"))

        let resolved: [URL]
        switch result {
        case .denied:
            print("    unreadable — Full Disk Access not granted. Skipped.")
            print("")
            return true
        case .missing:
            print("    not present on this machine. Skipped.")
            print("")
            return true
        case .ok(let urls):
            resolved = urls
        }

        // Pinning deliberately reorders the deck, so it is measured against the
        // pinned-aside sequence rather than being reported as a divergence.
        let unpinned = deck.filter { !$0.isPinned }
        let authoritative = unpinned.filter { $0.isAppleMenuAuthoritative }.map(\.url)
        let present = Set(authoritative)
        let expected = resolved.filter(present.contains)

        print("    \(resolved.count) entries, \(expected.count) of them in the deck")

        guard expected != authoritative else {
            print("    ✓ same order")
            print("")
            return true
        }

        let firstDivergence = zip(expected, authoritative).enumerated()
            .first { $0.element.0 != $0.element.1 }

        print("    ✗ order differs")
        if let (index, pair) = firstDivergence {
            print("      first at position \(index):")
            print("        Apple menu: \(pair.0.lastPathComponent)")
            print("        deck:       \(pair.1.lastPathComponent)")
        } else {
            print("      one sequence is a prefix of the other "
                  + "(\(expected.count) expected vs \(authoritative.count) shown)")
        }
        print("")
        return false
    }

    private static func printDeck(_ store: RecentsStore) {
        print(bold("  Deck as rendered"))
        if store.items.isEmpty { print("    (empty)") }

        for (index, item) in store.items.prefix(40).enumerated() {
            print("    \(String(format: "%2d", index)) \(pin(item)) "
                  + "[\(marker(item.origin))] \(kind(item.kind)) \(item.displayName)")
        }
        if store.items.count > 40 {
            print("    … and \(store.items.count - 40) more")
        }
    }

    static func marker(_ origin: RecentItem.Origin) -> String {
        switch origin {
        case .sharedFileList:     return "apple"
        case .spotlight:          return "spot "
        case .both:              return "both "
        case .runningApplication: return "run  "
        }
    }

    private static func kind(_ kind: RecentItem.Kind) -> String {
        switch kind {
        case .application: return "app "
        case .document:    return "doc "
        case .server:      return "srv "
        }
    }

    private static func pin(_ item: RecentItem) -> String { item.isPinned ? "📌" : "  " }

    private static func bold(_ text: String) -> String { "\u{001B}[1m\(text)\u{001B}[0m" }
}
