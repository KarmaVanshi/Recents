import Foundation

/// Performs the Apple menu's own "Recent Items ▸ Clear Menu", for real.
///
/// This is the one thing Recents does that reaches outside its own window: it
/// empties macOS's recent applications, documents and servers lists, so *every*
/// app's  menu is cleared, not just this deck.
///
/// Why it works by deleting files rather than by calling an API: there is none.
/// `LSSharedFileListRemoveAllItems` was the supported route until 10.11, when
/// Apple deprecated the whole `LSSharedFileList` surface and stopped vending the
/// recent-items lists through it — `LSSharedFileListCreate` returns NULL for
/// those constants now, so a call there is not a fallback, it is dead code. The
/// `SharedFileList.framework` replacement is private. What is left is the same
/// thing every "clear my recents" recipe does: remove the three files the Apple
/// menu reads, and make `sharedfilelistd` forget what it had cached.
///
/// Note the asymmetry with `UserState`: removing *one* entry this way is still
/// not possible, because rewriting a list `sharedfilelistd` owns races with its
/// in-memory copy and can corrupt it. Emptying all three is safe precisely
/// because the daemon is killed rather than negotiated with, and the state being
/// discarded is the state the user asked to discard.
///
/// Verified end-to-end on macOS 26.5: after `clear()`, every app's  menu shows
/// Recent Items holding nothing but its section headers, and the next document
/// opened is the *only* entry that comes back — the daemon relaunches with no
/// memory of what was there.
enum AppleMenuRecents {

    /// Exactly the three lists the Apple menu's Recent Items submenu shows.
    ///
    /// Per-app "Open Recent" menus live in
    /// `com.apple.LSSharedFileList.ApplicationRecentDocuments/` and are
    /// deliberately left alone — the real Clear Menu does not touch them either,
    /// and an action that quietly cleared more than the menu it is named after
    /// would be a worse kind of surprise than one that clears less.
    static let clearedLists: [SharedFileListReader.List] = [
        .recentApplications, .recentDocuments, .recentServers,
    ]

    enum ClearResult {
        /// `entries` is what was in the lists before they went.
        case cleared(entries: Int)
        /// Nothing on disk to clear — a machine that has never recorded a recent
        /// item, or a menu that was already cleared.
        case nothingToClear
        /// The lists exist but could not be removed: the Full Disk Access
        /// signature, the same one that stops them being read.
        case denied
    }

    /// Empties the three lists and returns what was in them.
    ///
    /// Synchronous, and briefly blocking on `killall` — this only ever runs from
    /// a user action that has already been confirmed, and the caller wants the
    /// daemon actually gone before it refreshes the deck.
    @discardableResult
    static func clear() -> ClearResult {
        let manager = FileManager.default

        // Counted before anything is touched, so the result can say what went.
        var entries = 0
        var present: [URL] = []
        for list in clearedLists {
            let url = SharedFileListReader.url(for: list)
            guard manager.fileExists(atPath: url.path) else { continue }
            present.append(url)
            if case .ok(let urls) = SharedFileListReader.read(list) {
                entries += urls.count
            }
        }

        guard !present.isEmpty else { return .nothingToClear }

        // The daemon is killed on both sides of the deletion, and the ordering is
        // the whole trick.
        //
        // Killing first empties the only writer, so nothing can rewrite a file
        // out from under the removal. Killing again afterwards covers the case
        // where launchd relaunched it on demand *during* the removal, in which
        // case it read the old lists into memory and would write them straight
        // back. After the second kill there is nothing left to reload from: the
        // next launch reads three absent files as three empty lists.
        terminateDaemon()

        var removed = 0
        var refused = false
        for url in present {
            do {
                try manager.removeItem(at: url)
                removed += 1
            } catch CocoaError.fileNoSuchFile {
                // Already gone between the survey and here. Not a failure.
            } catch {
                refused = true
            }
        }

        terminateDaemon()

        if removed == 0 { return refused ? .denied : .nothingToClear }
        return .cleared(entries: entries)
    }

    /// `sharedfilelistd` holds the lists in memory and owns the files on disk, so
    /// deleting them alone achieves nothing — the next item macOS records makes
    /// the daemon write its whole cached list back.
    ///
    /// `-9` rather than a polite `-TERM`: on a graceful shutdown the daemon
    /// flushes that cache to disk, which is exactly the state being thrown away.
    /// It is a per-user on-demand agent, so launchd starts it again the moment
    /// anything asks for a list; nothing is left broken by killing it outright.
    private static func terminateDaemon() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-9", "sharedfilelistd"]
        // "No matching processes" is a normal outcome, not something to report,
        // and an inherited descriptor is a leak into a child process.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
