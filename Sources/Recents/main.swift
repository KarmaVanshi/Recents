import AppKit
import Foundation

// `--dump` runs the data engine headless and prints the merged deck as text.
// This exists so the merge can be verified against the real Apple menu before
// any UI is written, and so the file-watcher can be proven to re-arm.
if CommandLine.arguments.contains("--selftest-watcher") {
    WatcherSelfTest.run()
} else if CommandLine.arguments.contains("--selftest-live") {
    // Verifies that minimised windows really are readable on this machine, and
    // which of them are actively drawing. See `LivePreviewSelfTest`.
    MainActor.assumeIsolated { LivePreviewSelfTest.run() }
} else if CommandLine.arguments.contains("--selftest-dock") {
    // Verifies that the Dock still exposes its tiles through Accessibility on
    // this release, and that hovering one would resolve to real windows with
    // real pixels behind them. See `DockSelfTest`.
    MainActor.assumeIsolated { DockSelfTest.run() }
} else if CommandLine.arguments.contains("--selftest-dock-close") {
    // Clicks the close button on a real Dock preview thumbnail, against a
    // scratch window this test creates. The one claim about the panel that
    // cannot be checked by reading anything. See `DockCloseSelfTest`.
    MainActor.assumeIsolated { DockCloseSelfTest.run() }
} else if CommandLine.arguments.contains("--selftest-dock-keys") {
    // Presses the arrow keys at a real Dock preview and reads back which
    // thumbnail ended up highlighted. Whether a keystroke reaches a panel that
    // never becomes key is a fact about the window server. See `DockKeySelfTest`.
    MainActor.assumeIsolated { DockKeySelfTest.run() }
} else if CommandLine.arguments.contains("--selftest-menu") {
    // Presses ↓ at the real status item menu and reads back what the menu
    // highlighted. Whether a menu answers the keyboard is a fact about AppKit
    // and the window server, not about this source. See `MenuSelfTest`.
    MainActor.assumeIsolated { MenuSelfTest.run() }
} else if CommandLine.arguments.contains("--selftest-gesture") {
    // Verifies that the private multitouch path delivers raw contacts on this
    // machine, and that a flat N-finger tap can be told apart from the swipe
    // that means Mission Control. See `TrackpadGestureSelfTest`.
    MainActor.assumeIsolated { TrackpadGestureSelfTest.run() }
} else if CommandLine.arguments.contains("--selftest-office") {
    // Verifies that Word, Excel and PowerPoint really do expand into their own
    // recents on this machine — the store it reads is undocumented Office
    // internals, so this is the check that it has not moved. See
    // `OfficeSelfTest`.
    MainActor.assumeIsolated { OfficeSelfTest.run() }
} else if CommandLine.arguments.contains("--parity") {
    // Compares the deck against macOS's own Recent Items lists and exits
    // non-zero on divergence. See `ParityReport`.
    ParityReport.run()
} else if CommandLine.arguments.contains("--dump") {
    DumpHarness.run(watching: CommandLine.arguments.contains("--watch"))
} else {
    // Top-level code is nonisolated, but everything AppKit touches here is
    // main-actor bound — and this *is* the main thread.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .accessory: lives in the menu bar with no Dock icon and no app menu,
        // which is what makes it feel like part of the system chrome.
        app.setActivationPolicy(.accessory)
        // The delegate is owned only by NSApplication's weak reference, so keep
        // a strong one alive for the process lifetime.
        appDelegateRetainer = delegate
        app.run()
    }
}

/// Holds the delegate alive; `NSApplication.delegate` is a weak reference.
var appDelegateRetainer: AppDelegate?

enum DumpHarness {
    static func run(watching: Bool) {
        let store = RecentsStore()
        var generation = 0

        store.onRefresh = {
            generation += 1
            print("\u{001B}[1m── refresh #\(generation) ─ \(Date().formatted(date: .omitted, time: .standard)) ──\u{001B}[0m")

            if store.needsFullDiskAccess {
                print("  ⚠︎ shared file lists unreadable — running Spotlight-only.")
                print("    Grant Full Disk Access to see true Apple-menu ordering.")
            }

            if store.items.isEmpty {
                print("  (no items)")
            }

            for (index, item) in store.items.prefix(40).enumerated() {
                let origin = ParityReport.marker(item.origin)
                let pin = item.isPinned ? "📌" : "  "
                let name = item.displayName.padded(to: 46)
                print("  \(String(format: "%2d", index)) \(pin) [\(origin)] \(name) \(item.subtitle)")
            }

            if store.items.count > 40 {
                print("  … and \(store.items.count - 40) more (\(store.items.count) total)")
            }
            print("")
        }

        store.start()

        if watching {
            print("Watching for changes. Open a document in another app; the list should reprint.")
            print("Press ⌃C to stop.\n")
            RunLoop.main.run()
        } else {
            // Give Spotlight a moment to finish its initial gather, then print
            // the settled result and leave.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                store.stop()
                exit(0)
            }
            RunLoop.main.run()
        }
    }
}

extension String {
    /// Pads or truncates for column alignment in the dump output.
    ///
    /// A name that is exactly `width` long is left alone rather than being
    /// truncated to make room for an ellipsis it does not need. A width of zero
    /// yields an empty column instead of trapping on `prefix(-1)`.
    func padded(to width: Int) -> String {
        guard width > 0 else { return "" }
        if count > width {
            return String(prefix(width - 1)) + "…"
        }
        return self + String(repeating: " ", count: width - count)
    }
}
