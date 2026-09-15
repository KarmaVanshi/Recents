import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Proves that a Dock preview answers the arrow keys, by pressing them.
///
/// Run: `Recents.app/Contents/MacOS/Recents --selftest-dock-keys`
///
/// Run the binary *inside the bundle*: an event tap needs Accessibility, and TCC
/// grants that to a bundle rather than to a loose executable. Without it the tap
/// is never created and every key falls through, which looks from outside
/// exactly like a panel that ignores the keyboard.
///
/// This exists because the claim is one that reading the code cannot settle. The
/// preview panel never becomes key and this application never activates, so the
/// keystroke the user makes is on its way to some other app entirely; whether it
/// reaches this one depends on a tap the window server has to agree to install.
/// That is a fact about the running system, so the test presses ← and → at a
/// real panel and reads back which thumbnail ended up highlighted.
///
/// It needs a tile with at least two windows behind it — one thumbnail cannot
/// show movement — and says so rather than passing when there was nothing to
/// move between.
@MainActor
enum DockKeySelfTest {

    private static var steps: [(key: String, expected: Int?, got: Int?)] = []

    static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        print("Dock preview keyboard navigation — self test\n")

        guard AXIsProcessTrusted() else {
            print("  ✗ Accessibility is not granted to this bundle, so neither the")
            print("    Dock can be read nor a key tapped. Grant it in System")
            print("    Settings › Privacy & Security › Accessibility.")
            exit(1)
        }
        print("  Event tap supported : \(DockPreviewKeys.isSupported ? "yes" : "no")")

        guard let strip = DockProbe.stripFrame() else {
            print("  ✗ The Dock's tile strip could not be located.")
            exit(1)
        }

        // A tile with more than one window, because the whole question is
        // whether the highlight *moves*.
        var chosen: (tile: DockProbe.Tile, count: Int)?
        var distance: CGFloat = 0
        let isVertical = strip.height > strip.width
        let length = isVertical ? strip.height : strip.width
        while distance <= length, chosen == nil {
            let point = isVertical
                ? CGPoint(x: strip.midX, y: strip.maxY - distance)
                : CGPoint(x: strip.minX + distance, y: strip.midY)
            distance += 8
            guard let tile = DockProbe.tile(at: point),
                  let target = DockWindows.target(for: tile),
                  target.windows.count > 1
            else { continue }
            chosen = (tile, target.windows.count)
        }

        guard let chosen else {
            print("  ✗ No Dock tile has two or more windows behind it, so there is")
            print("    nothing for the arrow keys to move between. Open a second")
            print("    window in some app and run this again.")
            exit(1)
        }

        let count = chosen.count
        print("  Tile                : \"\(chosen.tile.title)\" — \(count) windows")

        guard DockPreviewController.shared.showForSelfTest(chosen.tile) != nil else {
            print("  ✗ The panel refused to open.")
            exit(1)
        }
        print("  Panel               : open, nothing highlighted "
            + "(\(describe(DockPreviewController.shared.selectedIndex)))")
        print("")

        // Scheduled onto the real application loop, which is the only thing that
        // will deliver a synthesised keystroke — the same lesson
        // `DockCloseSelfTest` records about clicks.
        //
        // The expectations spell out the intended behaviour: → from nothing
        // takes the first thumbnail, → again steps along, ← steps back, and ←
        // at the first thumbnail stays put rather than wrapping round to the
        // last.
        // The pointer goes onto the panel before a key is pressed, because that
        // is now what decides whether these keys are the panel's at all — see
        // `DockPreviewSelection.panelOwnsKeyboard`. Onto the panel's own margin
        // rather than onto a thumbnail: hovering a picture would highlight it,
        // and the first expectation below is about → starting from nothing.
        let restore = NSEvent.mouseLocation

        // Re-asserted before every keystroke rather than once at the start. The
        // panel is placed as the run loop turns, so a single move scheduled
        // against the clock can land before there is a panel to land on — and a
        // key pressed with the pointer still elsewhere is now correctly ignored,
        // which made the whole run fail by one step for a reason that had
        // nothing to do with the keys. In use the pointer is on the panel for
        // the whole gesture anyway, so this is also the more faithful shape.
        record(at: 0.6, key: "→", kVK_RightArrow, expected: 0, onPanel: true)
        record(at: 1.1, key: "→", kVK_RightArrow, expected: min(1, count - 1), onPanel: true)
        record(at: 1.6, key: "←", kVK_LeftArrow, expected: 0, onPanel: true)
        record(at: 2.1, key: "←", kVK_LeftArrow, expected: 0, onPanel: true)

        // The pointer's half of the same highlight. The arrow keys and the
        // mouse now write to one piece of state, so a change that satisfied the
        // keyboard could have quietly stopped the hover reaching it — and the
        // hover is what reveals a thumbnail's close and zoom buttons.
        record(at: 2.6, key: "hover", expected: 0) { moveIntoFirstThumbnail() }
        record(at: 3.1, key: "away", expected: nil) { move(to: CGPoint(x: 4, y: 4)) }

        // And the rule that sends the keys back where they belong. With the
        // pointer off the panel, → is not the panel's key: it has to reach the
        // application the user is actually working in, leaving the highlight
        // exactly as the line above left it. This is the regression guard for a
        // preview that ate ←, →, Escape, Return and Space out of whatever was
        // being typed into, for as long as the pointer sat near the Dock.
        record(at: 3.6, key: "→ off", kVK_RightArrow, expected: nil)

        step(4.2) {
            move(to: restore)
            report()
        }

        NSApp.run()
    }

    /// Puts the pointer just inside the panel's top edge — on the panel, so the
    /// keys are its own, but clear of every thumbnail, so nothing is highlighted
    /// by arriving there.
    private static func moveOntoPanelMargin() {
        guard let panel = NSApp.windows.first(where: { $0.isVisible && $0 is DockPreviewPanel })
        else { return }
        move(to: CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 3))
    }

    /// Puts the pointer inside the first thumbnail's picture.
    ///
    /// Horizontally a short way in from the row's left edge, vertically the
    /// panel's own middle — which is inside the picture at every height the row
    /// can be laid out at, with the header above it and the caption below. The
    /// alternative, deriving the thumbnail's exact rectangle here, is how
    /// `DockCloseSelfTest` came to be clicking at a position the layout had
    /// moved out from under it.
    private static func moveIntoFirstThumbnail() {
        guard let panel = NSApp.windows.first(where: { $0.isVisible && $0 is DockPreviewPanel })
        else { return }
        move(to: CGPoint(
            x: panel.frame.minX + DockPreviewLayout.padding + 25,
            y: panel.frame.midY
        ))
    }

    /// Flipped about the *primary* display's height, which is what `CGEvent`
    /// measures from — a display stacked above it lives in negative territory,
    /// so taking the topmost edge of all of them offsets every point by that
    /// display's height. `DockProbe` flips the same way, and the two have to
    /// agree or this hovers somewhere the panel is not.
    private static func move(to point: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: point.x, y: primaryHeight - point.y),
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    private static func record(
        at delay: TimeInterval, key: String, _ keyCode: Int, expected: Int?,
        onPanel: Bool = false
    ) {
        record(at: delay, key: key, expected: expected) {
            if onPanel { moveOntoPanelMargin() }
            press(keyCode)
        }
    }

    /// Does something to the panel and writes down what the highlight became.
    private static func record(
        at delay: TimeInterval, key: String, expected: Int?,
        _ action: @escaping () -> Void
    ) {
        step(delay) {
            action()
            // A beat for the tap's callback to run and SwiftUI to catch up.
            step(0.25) {
                steps.append((key, expected, DockPreviewController.shared.selectedIndex))
            }
        }
    }

    private static func report() -> Never {
        print("  KEY   EXPECTED   GOT")
        var failed = false
        for step in steps {
            let ok = step.expected == step.got
            failed = failed || !ok
            print("  \(step.key.padded(to: 6))\(describe(step.expected).padded(to: 11))"
                + "\(describe(step.got).padded(to: 8))\(ok ? "✓" : "✗")")
        }
        print("")

        DockPreviewController.shared.hide()

        guard !steps.isEmpty else {
            print("  ✗ No keystroke was recorded at all.")
            exit(1)
        }
        guard !failed else {
            print("  ✗ The panel did not answer the arrow keys as intended.")
            print("    A row of \"—\" means the keystroke never reached the panel:")
            print("    the event tap was refused, or it was torn down early.")
            exit(1)
        }

        print("  ✓ ← and → move the highlight along the row, and it stops at the")
        print("    ends rather than wrapping.")
        print("  ✓ With the pointer off the panel the same keys are left alone,")
        print("    so they reach the application the user is working in.")
        exit(0)
    }

    private static func describe(_ index: Int?) -> String {
        index.map(String.init) ?? "—"
    }

    private static func step(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated(work)
        }
    }

    /// Posts a real key press through the window server, which is where the tap
    /// is listening. `NSApp.postEvent` would put it in this process's own queue
    /// and never pass a session tap at all.
    private static func press(_ keyCode: Int) {
        for isDown in [true, false] {
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: isDown
            )?.post(tap: .cghidEventTap)
            usleep(40_000)
        }
    }
}
