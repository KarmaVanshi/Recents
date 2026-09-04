import Foundation

/// Proves `FileWatcher` survives atomic replacement.
///
/// This is worth having as a permanent, runnable check because the bug it
/// guards against is invisible in casual testing: a watcher armed naively on a
/// file descriptor fires correctly the *first* time the file is replaced and
/// then goes silent forever. `sharedfilelistd` replaces the `.sfl4` files
/// atomically on every change, so a regression here would quietly turn the
/// whole deck static — no crash, no error, just stale data.
///
/// Run: `Recents --selftest-watcher`
enum WatcherSelfTest {

    /// Directory name prefix, shared by the sweep of previous runs' leftovers.
    private static let prefix = "recents-watcher-test-"

    static func run() {
        sweepOrphansFromPreviousRuns()

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Deliberately not `defer`. Both exits below call `exit()`, which
        // terminates the process without unwinding the stack, so a deferred
        // cleanup never runs at all — which is how previous runs left a trail of
        // temp directories behind them. `finish` does the removal itself.
        func finish(_ code: Int32) -> Never {
            try? FileManager.default.removeItem(at: dir)
            exit(code)
        }

        let target = dir.appendingPathComponent("list.sfl4")
        try? "generation 0".write(to: target, atomically: true, encoding: .utf8)

        let rounds = 3
        var fired = 0
        let lock = NSLock()
        let allDone = DispatchSemaphore(value: 0)

        let watcher = FileWatcher(url: target) {
            lock.lock()
            fired += 1
            let count = fired
            lock.unlock()
            print("  ✓ change \(count) detected")
            if count >= rounds { allDone.signal() }
        }

        print("Testing FileWatcher across \(rounds) atomic replacements…")
        print("(A naive watcher passes round 1 and then goes permanently silent.)\n")

        // Let the watcher arm before the first replacement.
        Thread.sleep(forTimeInterval: 0.4)

        for generation in 1...rounds {
            // Exactly how sharedfilelistd does it: write a temp file, then
            // rename it over the target. The original inode is unlinked, which
            // is what kills a naive watcher.
            let temp = dir.appendingPathComponent("tmp-\(generation)")
            try? "generation \(generation)".write(to: temp, atomically: false, encoding: .utf8)
            _ = try? FileManager.default.replaceItemAt(target, withItemAt: temp)
            print("  → replacement \(generation) written")
            Thread.sleep(forTimeInterval: 0.6)
        }

        let outcome = allDone.wait(timeout: .now() + 3.0)
        watcher.stop()

        lock.lock()
        let total = fired
        lock.unlock()

        print("")
        if outcome == .success || total >= rounds {
            print("PASS — watcher re-armed and caught all \(rounds) replacements.")
            finish(0)
        } else {
            print("FAIL — only \(total)/\(rounds) replacements detected.")
            print("The watcher stopped re-arming after the inode was unlinked.")
            finish(1)
        }
    }

    /// Clears anything an earlier build left behind, since the cleanup it
    /// intended never ran.
    private static func sweepOrphansFromPreviousRuns() {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporary, includingPropertiesForKeys: nil
        ) else { return }

        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
