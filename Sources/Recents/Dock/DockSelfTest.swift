import AppKit
import ApplicationServices

/// Proves the Dock preview path end to end, from the terminal.
///
/// Run: `Recents.app/Contents/MacOS/Recents --selftest-dock`
///
/// Run the binary *inside the bundle*, not one built loose by SwiftPM. TCC
/// grants Accessibility to a bundle, and this whole feature reads the Dock's
/// accessibility tree — a loose executable is a different client and will be
/// told it has no permission, which looks exactly like a broken feature.
///
/// This exists because the riskiest claim in the feature cannot be checked by
/// reading the code: that the Dock, on *this* release of macOS, still exposes a
/// list of `AXDockItem` children with positions, titles and URLs, and still
/// answers `AXUIElementCopyElementAtPosition`. That is another application's
/// internal accessibility tree, not an API contract, and it is the single point
/// on which everything else rests. Everything downstream of it — resolving a
/// tile to an app, an app to its windows, a window to pixels — is checked here
/// too, against whatever happens to be running right now.
///
/// It deliberately drives the same `DockProbe`, `DockWindows` and
/// `WindowServerCapture` the feature uses. A self-test with its own copy of the
/// logic would prove nothing about the app.
@MainActor
enum DockSelfTest {

    static func run() {
        // The window server and the accessibility client both refuse to talk to
        // a process that has not connected.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        print("Dock previews — self test\n")

        let trusted = AXIsProcessTrusted()
        print("  Accessibility granted      : \(mark(trusted))")
        print("  Screen Recording granted   : \(mark(CGPreflightScreenCaptureAccess()))")
        print("  SkyLight capture available : \(mark(WindowServerCapture.isAvailable))")
        print("  Preference enabled         : \(mark(Preferences.shared.dockPreviews))")
        print("")

        guard trusted else {
            print("  ✗ Without Accessibility the Dock cannot be asked what the pointer")
            print("    is over, and there is no degraded mode. Grant it to this bundle")
            print("    in System Settings › Privacy & Security › Accessibility.")
            exit(1)
        }

        guard let strip = DockProbe.stripFrame() else {
            print("  ✗ The Dock's tile strip could not be located. Neither its")
            print("    accessibility tree nor its window was recognisable, which means")
            print("    the hover watcher would reject every pointer position.")
            exit(1)
        }

        print("  Tile strip : \(describe(strip))")
        print("  Dock edge  : \(DockProbe.edge())")
        print("")

        waitForRememberedStills()

        let tiles = probeTiles(across: strip)
        guard !tiles.isEmpty else {
            print("  ✗ Hit testing found no Dock tiles anywhere along the strip.")
            print("    `AXUIElementCopyElementAtPosition` is the only way this app")
            print("    learns what the pointer is over, so previews cannot work.")
            exit(1)
        }

        if CommandLine.arguments.contains("--panel") {
            showPanel(for: tiles)
            return
        }

        report(tiles)

        // The feed is checked separately from the tiles, because "a window was
        // found and its pixels can be read" and "frames actually arrive in the
        // store a thumbnail reads from" are different claims, and only the
        // second one is what the user sees.
        runFeedCheck(on: tiles)

        exit(previewable(tiles) > 0 ? 0 : 1)
    }

    /// Puts a real preview panel on screen and leaves it there to be
    /// photographed.
    ///
    /// `--selftest-dock --panel`. The rest of this test proves the data reaches
    /// the store a thumbnail reads from; this is the only way to check that the
    /// thumbnail then draws it, short of a hand on the trackpad.
    private static func showPanel(for tiles: [DockProbe.Tile]) {
        // `--panel <name>` picks a particular tile, so both halves of the
        // feature can be photographed: a live window, and the remembered still
        // a running app with nothing open falls back to.
        let wanted = CommandLine.arguments
            .firstIndex(of: "--panel")
            .flatMap { index -> String? in
                let next = index + 1
                guard CommandLine.arguments.count > next,
                      !CommandLine.arguments[next].hasPrefix("--")
                else { return nil }
                return CommandLine.arguments[next]
            }

        let candidates = tiles.filter { DockWindows.target(for: $0) != nil }
        guard let tile = wanted.flatMap({ name in
            candidates.first { $0.title.localizedCaseInsensitiveContains(name) }
        }) ?? candidates.first else {
            print("  ✗ No tile has anything to preview.")
            exit(1)
        }

        // Built twice for the same tile, which is the case that used to lose the
        // live feed: hovering back to a tile, or a panel re-forming after a
        // window is closed, tears down a hierarchy naming the same windows as
        // the one replacing it. With the subscriptions owned by the panel rather
        // than by each thumbnail's appearance, the second build is no different
        // from the first — and this is the check that says so.
        _ = DockPreviewController.shared.showForSelfTest(tile)
        guard let number = DockPreviewController.shared.showForSelfTest(tile) else {
            print("  ✗ The panel refused to open for \(tile.title).")
            exit(1)
        }

        print("  PANEL WINDOW \(number)  (\(tile.title))")
        print("  screencapture -l\(number) -o panel.png")

        // Whether the panel that is now on screen is actually on the feed.
        //
        // The feed check below drives the engine directly, which proves the
        // engine works and nothing about the panel: the subscriptions are
        // registered when a panel is built, and a thumbnail that is not
        // subscribed shows the frame it was primed with and never another one —
        // a still wearing a live preview's clothes. A beat first, for SwiftUI to
        // finish building the hierarchy.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let target = DockWindows.target(for: tile), !target.windows.isEmpty {
            let followed = LiveWindowPreview.shared.followedWindows
            print("")
            for window in target.windows {
                let slot = LiveWindowPreview.shared.slot(forWindow: window.id)
                print("  on the feed: \(mark(followed.contains(window.id)).padded(to: 6))"
                    + "live: \(mark(slot.isLive).padded(to: 6))\(window.title ?? "—")")
            }
        }
        fflush(stdout)

        // Long enough to be photographed from a shell, then gone — this is a
        // real panel on the user's screen, not a fixture.
        RunLoop.main.run(until: Date().addingTimeInterval(10))
        exit(0)
    }

    /// Drives the real engine over a real tile's windows and reports what landed.
    private static func runFeedCheck(on tiles: [DockProbe.Tile]) {
        guard let target = tiles.lazy
            .compactMap({ DockWindows.target(for: $0) })
            .first(where: { !$0.windows.isEmpty })
        else { return }

        print("  FEED CHECK  (\(target.name))\n")
        let engine = LiveWindowPreview.shared
        engine.retain(.dock)
        for window in target.windows {
            engine.setDemand(.focused, forWindow: window.id)
        }
        engine.prime(target.windows.map { .window($0.id) })

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        for window in target.windows {
            let slot = engine.slot(forWindow: window.id)
            let size = slot.image.map { "\(Int($0.size.width))×\(Int($0.size.height)) pt" }
                ?? "no image"
            print("  \("".padded(to: 4))live: \(mark(slot.isLive).padded(to: 6))"
                + "\(size.padded(to: 20))\(window.title ?? "—")")
        }
        engine.clearWindowDemands()
        engine.release(.dock)

        // The same engine, entered the way the deck's cards enter it. One object
        // now serves both surfaces, so "the Dock panel works" is only half the
        // claim — this is the half that says the deck was not broken by sharing
        // it, and that both are reading the same window through the same path.
        engine.retain(.deck)
        engine.setDemand(.focused, for: target.bundleID)
        engine.prime([.application(target.bundleID)])

        let cardDeadline = Date().addingTimeInterval(1)
        while Date() < cardDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let card = engine.slot(for: target.bundleID)
        let cardSize = card.image.map { "\(Int($0.size.width))×\(Int($0.size.height)) pt" }
            ?? "no image"
        print("  \("".padded(to: 4))live: \(mark(card.isLive).padded(to: 6))"
            + "\(cardSize.padded(to: 20))deck card for \(target.name)")
        print("")

        engine.setDemand(nil, for: target.bundleID)
        engine.release(.deck)
    }

    /// Waits for the on-disk cache of remembered window stills to load.
    ///
    /// `AppWindowCapture` reads it on a background queue the first time it is
    /// touched, which is invisible in the app — it has been running for hours by
    /// the time anyone hovers anything — and a trap in a process that lives for
    /// two seconds. Without this, every tile for a closed app reports having
    /// nothing to show, when what it actually has is a still that had not
    /// finished loading yet.
    private static func waitForRememberedStills() {
        let deadline = Date().addingTimeInterval(2)
        while AppWindowCapture.shared.captures.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        print("  Remembered stills : \(AppWindowCapture.shared.captures.count) apps\n")
    }

    // MARK: - Probing

    /// Walks the strip and hit tests along it, exactly as a pointer travelling
    /// over the Dock would.
    ///
    /// Sampling rather than enumerating the accessibility tree's children is the
    /// point: enumeration would prove the tree has items in it, and what the
    /// feature actually depends on is that the Dock answers a *position* with
    /// the item at it. Those are different claims, and only the second one is
    /// ever asked at runtime.
    private static func probeTiles(across strip: CGRect) -> [DockProbe.Tile] {
        let isVertical = strip.height > strip.width
        let length = isVertical ? strip.height : strip.width
        // Well under one tile's width, so no tile can be stepped over.
        let step: CGFloat = 8

        var found: [DockProbe.Tile] = []
        var distance: CGFloat = 0
        while distance <= length {
            let point = isVertical
                ? CGPoint(x: strip.midX, y: strip.maxY - distance)
                : CGPoint(x: strip.minX + distance, y: strip.midY)
            distance += step

            guard let tile = DockProbe.tile(at: point) else { continue }
            guard !found.contains(where: { $0.isSameTile(as: tile) }) else { continue }
            found.append(tile)
        }
        return found
    }

    private static func report(_ tiles: [DockProbe.Tile]) {
        print("  DOCK TILES  (as the hover watcher would see them)\n")
        print("  \("KIND".padded(to: 12))\("TITLE".padded(to: 28))"
            + "\("WINDOWS".padded(to: 9))PREVIEW")

        for tile in tiles {
            let kind = tile.kind == .application ? "app" : "minimised"
            guard let target = DockWindows.target(for: tile) else {
                // The two reasons a tile shows nothing are worth telling apart:
                // an app with no dot under it is *declining* to preview, which
                // is the rule; anything else is a tile the resolver could not
                // make sense of.
                let why = tile.isRunning == false
                    ? "not running — no preview"
                    : "no windows to show"
                print("  \(kind.padded(to: 12))\(tile.title.padded(to: 28))"
                    + "\("—".padded(to: 9))\(why)")
                continue
            }

            let count = target.windows.isEmpty ? "still" : "\(target.windows.count)"
            print("  \(kind.padded(to: 12))\(tile.title.padded(to: 28))"
                + "\(count.padded(to: 9))\(verdict(for: target))")

            for window in target.windows {
                let state = window.isOnScreen ? "on screen" : "minimised"
                let size = "\(Int(window.bounds.width))×\(Int(window.bounds.height))"
                // The document a window has open is what a still of it will
                // promise to reopen once the window is gone, so it is worth
                // seeing whether the app answers for it while it is still here.
                let document = DockWindows.document(of: window)?.lastPathComponent
                print("  \("".padded(to: 12))  ↳ \(state.padded(to: 11))"
                    + "\(size.padded(to: 12))\(window.title ?? "—")"
                    + (document.map { "  [\($0)]" } ?? ""))
                // The thumbnail's close button presses this window's own close
                // button, and every way that can fail is invisible from
                // outside — so it is reported here rather than discovered by a
                // user whose click did nothing.
                print("  \("".padded(to: 12))    close: "
                    + "\(DockWindows.closeReadiness(of: window))")
            }
        }
        print("")

        let count = previewable(tiles)
        if count > 0 {
            print("  ✓ \(count) of \(tiles.count) tiles would show a preview on hover.")
        } else {
            print("  ✗ No tile resolved to a window. Open an app with a window, or")
            print("    minimise one, and run this again.")
        }
    }

    /// Whether a real frame comes back for this target's first window — the last
    /// link in the chain, and the one that fails quietly when Screen Recording
    /// is missing.
    private static func verdict(for target: DockWindows.Target) -> String {
        guard let window = target.windows.first else {
            guard let still = target.still else { return "nothing to show" }
            let age = Int(Date().timeIntervalSince(still.capturedAt) / 60)
            // What a click on the still would do is part of the verdict: the
            // panel promises it on the badge, and a promise nobody checked is
            // the kind that turns out to open the wrong thing.
            return "remembered \(Int(still.image.size.width))×"
                + "\(Int(still.image.size.height)) (\(age)m old) — "
                + AppWindowCapture.openPromise(document: target.document)
        }
        guard WindowServerCapture.isAvailable else { return "stills only (no SkyLight)" }

        // Off the main thread, because that is the only way this call is ever
        // allowed to be made — see `WindowServerCapture.image`.
        let group = DispatchGroup()
        var image: CGImage?
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            image = WindowServerCapture.image(ofWindow: window.id, timeout: 1.0)
            group.leave()
        }
        guard group.wait(timeout: .now() + 2) == .success else { return "capture timed out" }

        guard let image else { return "no pixels (check Screen Recording)" }
        return FrameSample.of(image).isBlank
            ? "blank frame — window has not drawn"
            : "live \(image.width)×\(image.height)"
    }

    private static func previewable(_ tiles: [DockProbe.Tile]) -> Int {
        tiles.filter { DockWindows.target(for: $0) != nil }.count
    }

    // MARK: - Formatting

    private static func mark(_ value: Bool) -> String { value ? "yes" : "no" }

    private static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.width))×\(Int(rect.height)) at (\(Int(rect.minX)), \(Int(rect.minY)))"
    }
}
