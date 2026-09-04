import AppKit
import CoreGraphics

/// Proves the live-preview path end to end, from the terminal.
///
/// Run: `Recents --selftest-live`
///
/// This exists because the claim the feature rests on — that a *minimized*
/// window's pixels are readable, and that they keep changing while the app
/// draws — is exactly the kind of claim that is easy to assert and easy to get
/// wrong. It samples every real window on the system twice over a couple of
/// seconds and reports which ones moved, so the answer comes from this machine
/// rather than from documentation.
///
/// It deliberately uses the same `WindowServerCapture` the deck uses. A self-test
/// that exercised a private copy of the logic would prove nothing about the app.
@MainActor
enum LivePreviewSelfTest {

    /// Every window the server will admit to, before any of this file's
    /// filtering — which is the only way to tell "we rejected it" apart from
    /// "the window server does not have it", and those have completely different
    /// fixes. An app running with no window of its own shows up here as a couple
    /// of undersized strips and nothing else.
    private static func printRawWindowList() {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        print("  RAW WINDOW LIST  (everything the server lists, unfiltered)\n")
        print("  \("OWNER".padded(to: 24))\("SIZE".padded(to: 12))"
            + "\("ON SCREEN".padded(to: 11))TITLE")
        for entry in raw {
            let rect = entry[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let size = "\(Int(rect["Width"] ?? 0))×\(Int(rect["Height"] ?? 0))"
            let onScreen = (entry[kCGWindowIsOnscreen as String] as? Bool ?? false) ? "yes" : "no"
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
            let title = entry[kCGWindowName as String] as? String ?? ""
            print("  \(owner.padded(to: 24))\(size.padded(to: 12))"
                + "\(onScreen.padded(to: 11))\(title.isEmpty ? "—" : title)")
        }
        print("")
    }

    static func run() {
        // The window server refuses to talk to a process that has not connected.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        print("Live window preview — self test\n")

        print("  SkyLight capture available : \(mark(WindowServerCapture.isAvailable))")
        print("  Screen Recording granted   : \(mark(CGPreflightScreenCaptureAccess()))")

        guard WindowServerCapture.isAvailable else {
            print("\n  ✗ The private capture path is unavailable on this OS.")
            print("    Cards will fall back to ScreenCaptureKit stills.")
            exit(1)
        }

        if CommandLine.arguments.contains("--verbose") { printRawWindowList() }

        let windows = WindowServerCapture.candidateWindows()
        let best = WindowServerCapture.bestWindowPerProcess(from: windows)
        let onScreen = best.values.filter(\.isOnScreen).count
        let offScreen = best.count - onScreen

        print("  Applications with a window : \(best.count)"
            + "  (\(onScreen) on screen, \(offScreen) minimised or hidden)\n")

        // Two passes a beat apart. Anything whose fingerprint changes between
        // them is genuinely rendering, which is the only thing that makes a
        // moving preview possible.
        var first: [pid_t: UInt64] = [:]
        var sizes: [pid_t: String] = [:]
        var failures: [pid_t] = []

        // Off the main thread: the capture SPI blocks, and on a loaded machine it
        // can block for seconds. Doing this inline is exactly the mistake the
        // main-thread guard in `WindowServerCapture` exists to catch.
        for (pid, window) in best {
            guard let image = captureOffMainThread(window.id) else {
                failures.append(pid)
                continue
            }
            first[pid] = FrameSample.of(image).hash
            sizes[pid] = "\(image.width)×\(image.height)"
        }

        Thread.sleep(forTimeInterval: 1.2)

        var rows: [(name: String, state: String, size: String, moved: Bool)] = []
        for (pid, window) in best {
            guard let before = first[pid],
                  let image = captureOffMainThread(window.id)
            else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            rows.append((
                name: name,
                state: window.isOnScreen ? "on screen" : "MINIMISED",
                size: sizes[pid] ?? "?",
                moved: FrameSample.of(image).hash != before
            ))
        }

        rows.sort { ($0.state, $0.name) < ($1.state, $1.name) }

        print("  \("APPLICATION".padded(to: 30))\("STATE".padded(to: 12))"
            + "\("PIXELS".padded(to: 14))CONTENT")
        for row in rows {
            print("  \(row.name.padded(to: 30))\(row.state.padded(to: 12))"
                + "\(row.size.padded(to: 14))\(row.moved ? "moving ✓" : "static")")
        }

        let minimised = rows.filter { $0.state == "MINIMISED" }
        let movingMinimised = minimised.filter(\.moved)

        print("\n  Captured \(rows.count) of \(best.count) windows"
            + (failures.isEmpty ? "" : " (\(failures.count) refused)"))
        print("  Minimised windows readable : \(minimised.count)")
        print("  …of those, actively drawing: \(movingMinimised.count)")

        if !minimised.isEmpty {
            print("\n  ✓ Minimised windows are readable — the thing ScreenCaptureKit cannot do.")
            if movingMinimised.isEmpty {
                print("    None happened to be animating just now. Play a video in a")
                print("    minimised window and run this again to see one move.")
            }
        } else {
            print("\n  (Nothing was minimised, so the offscreen case went untested.")
            print("   Minimise a window and run this again.)")
        }

        exit(rows.isEmpty ? 1 : 0)
    }

    private static func mark(_ value: Bool) -> String { value ? "yes" : "NO" }

    /// Hops onto a background thread and waits there, so the blocking capture
    /// never runs on the main thread.
    private static func captureOffMainThread(_ windowID: CGWindowID) -> CGImage? {
        // A locked box rather than a captured `var`, and the result is only read
        // when the wait actually succeeded.
        //
        // The previous version read the variable regardless of how the wait
        // ended, so on a timeout the background block could still be writing it
        // while this thread read it — the exact race `WindowServerCapture`'s own
        // comments warn against, and one the compiler flags outright ("mutation
        // of captured var in concurrently-executing code").
        let box = ImageBox()
        let done = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            box.image = WindowServerCapture.image(ofWindow: windowID, timeout: 2)
            done.signal()
        }

        guard done.wait(timeout: .now() + 3) == .success else { return nil }
        return box.image
    }

    private final class ImageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CGImage?

        var image: CGImage? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
