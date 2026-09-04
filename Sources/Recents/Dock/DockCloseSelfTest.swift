import AppKit
import ApplicationServices

/// Proves that the close button on a Dock preview thumbnail actually closes a
/// window, by clicking it.
///
/// Run: `Recents.app/Contents/MacOS/Recents --selftest-dock-close`
///
/// This exists because the failure it was written for was invisible from every
/// other angle. The panel drew, the cross appeared on hover, the click landed on
/// it, the button ran its action — and the window stayed open, because the
/// accessibility lookup behind it came back empty and `DockWindows.close`
/// discarded the fact. Reading the code proved nothing; hovering a real tile and
/// clicking proved it, so that is what this does.
///
/// It experiments on a window it creates — a scratch document in TextEdit —
/// rather than on anything of the user's, because the test's whole purpose is to
/// close a window and closing is not undoable. The pointer is moved to click the
/// cross and put back afterwards.
///
/// Three outcomes are distinguishable from outside, which is what makes this
/// worth running: the window is gone (the cross works), the window is still
/// there and TextEdit came to the front (the click fell through to the thumbnail
/// underneath and raised the window instead), or nothing happened at all.
@MainActor
enum DockCloseSelfTest {

    private static let scratchName = "recents-close-selftest.txt"

    static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        print("Dock preview close button — self test\n")

        guard AXIsProcessTrusted() else {
            print("  ✗ Accessibility is not granted to this bundle, so neither the")
            print("    Dock nor any window can be reached. Grant it in System")
            print("    Settings › Privacy & Security › Accessibility.")
            exit(1)
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(scratchName)
        try? "Scratch document for the Dock preview close test.\n"
            .write(to: scratch, atomically: true, encoding: .utf8)

        let configuration = NSWorkspace.OpenConfiguration()
        // Left in the background deliberately: the panel's whole premise is
        // acting on a window without activating its app, and a test that
        // activated TextEdit first would not be testing that.
        configuration.activates = false
        NSWorkspace.shared.open(
            [scratch],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: configuration
        )

        var app: NSRunningApplication?
        var window: WindowServerCapture.WindowRef?
        wait(10) {
            app = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.TextEdit"
            ).first { !$0.isTerminated }
            guard let pid = app?.processIdentifier else { return false }
            window = WindowServerCapture.candidateWindows().first {
                $0.pid == pid && $0.title?.contains(scratchName) == true
            }
            return window != nil
        }
        guard let app, let window else {
            print("  ✗ The scratch TextEdit window never appeared, so there is")
            print("    nothing to experiment on.")
            exit(1)
        }
        print("  Scratch window : id \(window.id) "
            + "\(Int(window.bounds.width))×\(Int(window.bounds.height))")
        print("  Close readiness: \(DockWindows.closeReadiness(of: window))")

        // Recorded before anything is clicked, because "the app no longer
        // answers for this window" only means the window went away if the app
        // answered for it to begin with. Some apps never expose a window through
        // Accessibility at all — Notes, minimized, measured on macOS 26 — and
        // for one of those an absent element after the click would prove nothing.
        let resolvedBeforeClick = DockWindows.resolve(window).element != nil

        guard let strip = DockProbe.stripFrame() else {
            print("  ✗ The Dock's tile strip could not be located.")
            finish(app, scratch, window: window, code: 1)
        }

        // The tile is found by asking which one resolves to the scratch window,
        // rather than by looking for a tile called "TextEdit". It is the same
        // question the hover watcher asks, and it cannot pick the wrong tile.
        var tile: DockProbe.Tile?
        wait(8) {
            tile = tiles(across: strip).first { candidate in
                DockWindows.target(for: candidate)?.windows
                    .contains { $0.id == window.id } == true
            }
            return tile != nil
        }
        guard let tile else {
            print("  ✗ No Dock tile resolved to the scratch window.")
            finish(app, scratch, window: window, code: 1)
        }
        print("  Dock tile      : \"\(tile.title)\"")

        guard let number = DockPreviewController.shared.showForSelfTest(tile),
              let panel = NSApp.windows.first(where: { $0.windowNumber == number })
        else {
            print("  ✗ The panel refused to open for \(tile.title).")
            finish(app, scratch, window: window, code: 1)
        }

        // Where to click, asked of the layout the panel was actually built
        // from rather than reconstructed here.
        //
        // It used to be reconstructed — 14pt of padding, a thumbnail 132pt tall,
        // a control 37pt in from its right edge — and every one of those numbers
        // was true when it was written. Then the row learned to shrink to fit the
        // screen, and a header appeared above it, and this test went on clicking
        // a spot 24pt above the picture and reporting the close button as broken.
        // A test that keeps its own copy of a layout ends up testing the copy.
        //
        // The thumbnail is found by window rather than assumed to be first:
        // TextEdit may have windows of the user's own open beside the scratch one.
        guard let target = DockWindows.target(for: tile),
              let index = target.windows.firstIndex(where: { $0.id == window.id }),
              let layout = DockPreviewController.shared.shownLayout,
              let centre = layout.closeButtonCentre(forThumbnailAt: index)
        else {
            print("  ✗ The panel is up but has no thumbnail for the scratch")
            print("    window, so there is no cross to press.")
            finish(app, scratch, window: window, code: 1)
        }

        let cross = CGPoint(
            x: panel.frame.minX + centre.x, y: panel.frame.maxY - centre.y
        )
        // Somewhere inside the same picture, to reveal the controls first. The
        // panel's own middle is inside every thumbnail at every height the row
        // can be laid out at, with the header above it and the caption below.
        let body = CGPoint(
            x: panel.frame.minX + centre.x - layout.widths[index] / 2,
            y: panel.frame.midY
        )

        print("  Panel          : \(Int(panel.frame.width))×"
            + "\(Int(panel.frame.height)) at (\(Int(panel.frame.minX)), "
            + "\(Int(panel.frame.minY)))")
        print("  Thumbnail      : \(index + 1) of \(target.windows.count), "
            + "\(Int(layout.widths[index]))×\(Int(layout.height))")
        print("  Cross at       : (\(Int(cross.x)), \(Int(cross.y)))")
        print("")

        let restore = NSEvent.mouseLocation

        // From here the steps are scheduled on the main queue and the real
        // application event loop is started. That is the only thing that
        // dispatches an NSEvent to a window: under a bare `RunLoop.run(until:)`
        // a synthesised click sits in the queue undelivered, which looks
        // exactly like a panel that ignores the mouse. This cost an hour once.
        step(0.8) {
            // Onto the thumbnail first, because the controls are revealed by
            // hover and there is nothing at the cross's position until then.
            move(to: body)
        }
        step(1.6) { move(to: cross) }
        step(2.4) {
            // `--no-click` runs everything up to the click and then does not
            // click, which is how "the cross broke this window" is told apart
            // from "this window was going to end up like that anyway".
            guard !CommandLine.arguments.contains("--no-click") else {
                print("  (--no-click: not clicking)")
                return
            }
            click(at: cross)
        }
        step(2.5) {
            // Polled rather than checked once. A closed window does not leave
            // the window server's list the instant its app lets go of it — the
            // entry lingers, titled and offscreen, for anything up to a few
            // seconds — so a single look a moment after the click reports a
            // window that has in fact gone.
            //
            // And leaving that list is not the only proof, which is the lesson
            // this poll was failing to apply to its own evidence. The entry can
            // outlive the window for longer than any deadline worth waiting: the
            // window server holds a window for as long as anything holds its
            // surface, and this process is not the only thing on the machine that
            // can be holding one — a second copy of Recents with Dock previews on
            // will have subscribed to the very same window when the pointer
            // crossed the tile. So the app's own answer counts too. A window that
            // resolved through Accessibility before the click and does not
            // resolve after it has been let go of by the application that owned
            // it, whatever list it is still named in, and that is what the cross
            // was asked to do. The test used to print exactly that evidence —
            // "no AX element" — directly underneath the verdict "the window did
            // not close".
            let clickedAt = Date()
            poll(deadline: 8) {
                let listed = WindowServerCapture.candidateWindows()
                    .contains { $0.id == window.id }
                guard listed else { return true }
                return resolvedBeforeClick && DockWindows.resolve(window).element == nil
            } then: { closed in
                let elapsed = String(
                    format: "%.1fs", Date().timeIntervalSince(clickedAt)
                )
                let lingering = WindowServerCapture.candidateWindows()
                    .contains { $0.id == window.id }
                print("  Close attempts    : \(DockPreviewController.closeAttempts)")
                print("  Close outcome     : "
                    + "\(DockPreviewController.lastCloseOutcome?.describe ?? "never called")")
                print("  Window closed     : \(closed ? "yes, after \(elapsed)" : "no")")
                if closed && lingering {
                    // Worth saying rather than passing quietly: it is the
                    // condition `LiveWindowPreview.forgetWindow` exists for, and
                    // a run where it appears is a run where something on this
                    // machine is still holding the window's surface.
                    print("    (its window-server entry is still listed — "
                        + "something still holds the surface)")
                }
                print("  TextEdit active   : \(app.isActive ? "yes" : "no")")
                print("")

                move(to: restore)
                DockPreviewController.shared.hide()

                if closed {
                    print("  ✓ The cross closed the window.")
                    finish(app, scratch, window: nil, code: 0)
                } else {
                    if app.isActive {
                        print("  ✗ The click fell through to the thumbnail and")
                        print("    raised the window instead of closing it.")
                    } else if DockPreviewController.closeAttempts == 0 {
                        print("  ✗ The cross was never pressed.")
                    } else {
                        print("  ✗ The cross was pressed and the window did not")
                        print("    close.")
                    }
                    print("    hidden: " + String(app.isHidden))
                    print("    " + DockWindows.closeReadiness(of: window))
                    print("    still draws pixels: " + drawsPixels(window))
                    for reference in WindowServerCapture.candidateWindows()
                    where reference.pid == app.processIdentifier {
                        print("    window id " + String(reference.id)
                            + "  onScreen " + String(reference.isOnScreen)
                            + "  \"" + (reference.title ?? "—") + "\"")
                    }
                    finish(app, scratch, window: window, code: 1)
                }
            }
        }

        NSApp.run()
    }

    /// Leaves nothing behind: the scratch window closed, TextEdit quit, the file
    /// deleted. A test that litters is a test people stop running.
    private static func finish(
        _ app: NSRunningApplication,
        _ scratch: URL,
        window: WindowServerCapture.WindowRef?,
        code: Int32
    ) -> Never {
        if let window { DockWindows.close(window: window) }
        wait(1) { false }
        app.terminate()
        try? FileManager.default.removeItem(at: scratch)
        exit(code)
    }

    /// Repeats `condition` on the main queue until it holds or the deadline
    /// passes, then hands the answer to `then`. On the main queue rather than in
    /// a loop, because the application event loop has to keep running: it is
    /// what delivers the click whose effect is being waited for.
    private static func poll(
        deadline seconds: TimeInterval,
        _ condition: @escaping () -> Bool,
        then finished: @escaping (Bool) -> Void
    ) {
        let limit = Date().addingTimeInterval(seconds)
        func attempt() {
            if condition() { finished(true); return }
            guard Date() < limit else { finished(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { attempt() }
            }
        }
        attempt()
    }

    /// Whether the window server will still hand over a frame for this window.
    /// A window whose entry lingers in the list after its app has let go of it
    /// has nothing left to draw, which is how a stale entry is told apart from
    /// a window that is genuinely still there.
    private static func drawsPixels(_ window: WindowServerCapture.WindowRef) -> String {
        guard WindowServerCapture.isAvailable else { return "cannot tell" }
        let group = DispatchGroup()
        var image: CGImage?
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            image = WindowServerCapture.image(ofWindow: window.id, timeout: 1.0)
            group.leave()
        }
        guard group.wait(timeout: .now() + 2) == .success else { return "timed out" }
        guard let image else { return "no" }
        return FrameSample.of(image).isBlank
            ? "blank \(image.width)×\(image.height)"
            : "yes, \(image.width)×\(image.height)"
    }

    private static func step(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated(work)
        }
    }

    /// Walks the Dock strip exactly as `DockSelfTest` does, hit testing along it.
    private static func tiles(across strip: CGRect) -> [DockProbe.Tile] {
        let isVertical = strip.height > strip.width
        let length = isVertical ? strip.height : strip.width
        var found: [DockProbe.Tile] = []
        var distance: CGFloat = 0
        while distance <= length {
            let point = isVertical
                ? CGPoint(x: strip.midX, y: strip.maxY - distance)
                : CGPoint(x: strip.minX + distance, y: strip.midY)
            distance += 8
            guard let tile = DockProbe.tile(at: point) else { continue }
            guard !found.contains(where: { $0.isSameTile(as: tile) }) else { continue }
            found.append(tile)
        }
        return found
    }

    // MARK: - Synthesised input

    /// AppKit's screen coordinates put the origin at the bottom left and
    /// `CGEvent`'s put it at the top left of the *primary* display, so every
    /// point is flipped about that display's height on the way out.
    ///
    /// The primary display's, not the topmost edge of all of them. `CGEvent`
    /// measures from the primary and puts anything above it in negative
    /// territory, so measuring from the top of a screen stacked above it would
    /// offset every click by that screen's height — the pointer would go
    /// somewhere else entirely and this test would report a working close button
    /// as broken. `DockProbe.primaryHeight` flips the same way for the same
    /// reason; the two have to agree or the test aims at a panel the app placed
    /// somewhere else.
    private static func flipped(_ point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.maxY
            ?? NSScreen.main?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private static func move(to point: CGPoint) {
        CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: flipped(point), mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    private static func click(at point: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: flipped(point), mouseButton: .left
            )?.post(tap: .cghidEventTap)
            usleep(60_000)
        }
    }

    private static func wait(_ seconds: TimeInterval, until: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if until() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
