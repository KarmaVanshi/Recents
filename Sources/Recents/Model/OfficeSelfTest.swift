import AppKit
import Foundation

/// Proves the Office adapter against the real machine, end to end.
///
/// Run with `--selftest-office`. It reads the three bookmark stores directly,
/// then goes back through the live `RecentsStore` and asks the same question the
/// application card asks — `hasRecentDocuments` and `recentDocuments(forApp:)` —
/// so a pass means the sub-deck genuinely has content, not merely that a plist
/// parsed.
///
/// Exits non-zero when the deck disagrees with the store. An app whose recorded
/// documents have all been moved or deleted is *expected* to offer no sub-deck
/// and no chevron, and that counts as a pass — it is the case that was silently
/// wrong before, since a chevron promising an empty sub-deck is worse than none.
///
/// This exists because the store is undocumented Office internals: the check
/// that matters is not "does the code compile" but "does it still work on this
/// machine, today".
enum OfficeSelfTest {

    /// Mirrors `RecentsStore.maximumDocumentsPerApp`, which is private. Kept
    /// here as the *expectation* rather than shared with it on purpose: a test
    /// that imports the number it is checking cannot catch it changing.
    private static let expectedCap = 6

    static func run() {
        print(bold("Office recents — direct read"))

        /// bundle identifier → how many of its documents are still on disk,
        /// capped the way the deck caps them. The deck is checked against this.
        var expected: [String: Int] = [:]

        for bundleID in OfficeRecentsReader.bundleIDs {
            let path = OfficeRecentsReader.url(forBundleID: bundleID).path
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")

            switch OfficeRecentsReader.read(bundleID: bundleID) {
            case .missing:
                print("  \(bundleID): not installed / no store")
                print("    \(dim(path))")
            case .denied:
                print("  \(bundleID): \(red("unreadable — Full Disk Access"))")
                print("    \(dim(path))")
            case .ok(let entries):
                let live = entries.filter {
                    FileManager.default.fileExists(atPath: $0.url.path)
                }
                expected[bundleID] = min(live.count, expectedCap)
                print("  \(bundleID): \(entries.count) documents, \(live.count) still on disk")
                for entry in live.prefix(expectedCap) {
                    let when = entry.lastUsed.formatted(date: .abbreviated, time: .shortened)
                    print("      \(when.padded(to: 26)) \(entry.url.lastPathComponent)")
                }
            }
        }

        guard !expected.isEmpty else {
            print("\n  No Office app on this machine — nothing to verify.")
            exit(0)
        }

        print("")
        print(bold("Through the deck — what an app card would expand into"))

        // The real path: start the store, let the background index land, then
        // ask it exactly what `DeckView.canDrillInto` and `drillInto` ask.
        let store = RecentsStore()
        store.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            var failures = 0

            for bundleID in OfficeRecentsReader.bundleIDs {
                guard let want = expected[bundleID] else { continue }

                guard let appURL = NSWorkspace.shared
                    .urlForApplication(withBundleIdentifier: bundleID) else {
                    print("  \(bundleID): \(red("LaunchServices does not know this app"))")
                    failures += 1
                    continue
                }

                // Built the way `loadApplications` builds one, so the lookup
                // goes through `RecentItem.bundleID` — the case-folding step
                // that a hand-made key would quietly skip.
                var item = RecentItem(
                    url: appURL, rank: 0, lastUsed: nil,
                    owningApp: appURL, origin: .runningApplication
                )
                item.kind = .application

                let canExpand = store.hasRecentDocuments(item)
                let documents = store.recentDocuments(forApp: item)

                // Two things have to agree: the deck shows exactly the live
                // documents the store holds, capped; and the chevron promises a
                // sub-deck if and only if there is one.
                let name = item.displayName
                let matches = documents.count == want && canExpand == (want > 0)

                if matches {
                    print("  \(green("✓")) \(name.padded(to: 22)) "
                          + "chevron: \(canExpand ? "yes" : "no ") · \(documents.count) card(s)")
                    for document in documents {
                        print("      · \(document.displayName)")
                    }
                    if want == 0 {
                        print("      \(dim("every recorded document has been moved or deleted"))")
                    }
                } else {
                    print("  \(red("✗")) \(name.padded(to: 22)) "
                          + "chevron: \(canExpand) · \(documents.count) card(s), "
                          + "expected \(want)")
                    failures += 1
                }
            }

            store.stop()
            print("")
            if failures == 0 {
                print(green("Deck matches every Office store on this machine."))
                exit(0)
            } else {
                print(red("\(failures) Office app(s) disagree with their store."))
                exit(1)
            }
        }

        RunLoop.main.run()
    }

    private static func bold(_ text: String) -> String { "\u{001B}[1m\(text)\u{001B}[0m" }
    private static func dim(_ text: String) -> String { "\u{001B}[2m\(text)\u{001B}[0m" }
    private static func red(_ text: String) -> String { "\u{001B}[31m\(text)\u{001B}[0m" }
    private static func green(_ text: String) -> String { "\u{001B}[32m\(text)\u{001B}[0m" }
}
