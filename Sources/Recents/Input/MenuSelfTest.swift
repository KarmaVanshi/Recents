import AppKit
import Carbon.HIToolbox

/// Proves that the status item's menu can be driven from the keyboard.
///
/// Run: `Recents.app/Contents/MacOS/Recents --selftest-menu`
///
/// Run the binary *inside the bundle*: synthesising a click and a keystroke
/// needs Accessibility, and TCC grants that to a bundle rather than to a loose
/// executable.
///
/// This exists because the claim cannot be checked by reading anything. A menu
/// popped from a status item is presented by AppKit, tracked in its own nested
/// event loop, and fed by the window server — none of which is visible in this
/// app's source. Whether ↓ moves the highlight is therefore a fact about the
/// running system, and the only honest way to establish it is to press the key
/// and read back what the menu highlighted.
///
/// The menu is opened by right-clicking the real status item, not by calling
/// `showMenu` directly. How a menu is presented is exactly what decides whether
/// it answers the keyboard — a menu popped from inside a mouse event is tracked
/// differently from one popped from a bare function call — so the test makes the
/// user's own gesture rather than one that merely ends in the same menu.
@MainActor
enum MenuSelfTest {

    private static var item: MenuBarItem?
    private static var itemCount = 0
    private static var afterFirst: String?
    private static var afterSecond: String?

    static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        print("Status menu keyboard navigation — self test\n")

        guard AXIsProcessTrusted() else {
            print("  ✗ Accessibility is not granted to this bundle, so neither a")
            print("    click nor a keystroke can be synthesised. Grant it in System")
            print("    Settings › Privacy & Security › Accessibility.")
            exit(1)
        }

        let store = RecentsStore()
        let controller = DeckWindowController(store: store)
        item = MenuBarItem(controller: controller, store: store)

        // The menu bar needs a turn of the event loop before it has placed the
        // item anywhere, so every step is scheduled and the real application
        // loop is started below. It is also the only loop that dispatches a
        // synthesised click to a status item — see `DockCloseSelfTest`, which
        // learned the same thing the expensive way.
        step(1.0) { openMenu() }
        step(2.0) { press(kVK_DownArrow) }
        step(2.5) { afterFirst = highlight() }
        step(2.9) { press(kVK_DownArrow) }
        step(3.4) { afterSecond = highlight() }
        step(3.7) { press(kVK_Escape) }
        step(4.3) { report() }

        NSApp.run()
    }

    /// Right-clicks the status item, which is the gesture that opens the menu —
    /// a left click summons the deck instead.
    private static func openMenu() {
        guard let frame = item?.buttonFrame else {
            print("  ✗ The status item never appeared in the menu bar, so there is")
            print("    no menu to open.")
            exit(1)
        }

        let point = CGPoint(x: frame.midX, y: frame.midY)
        print("  Status item       : \(Int(frame.width))×\(Int(frame.height)) "
            + "at (\(Int(frame.minX)), \(Int(frame.minY)))")

        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(
                mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: flipped(point), mouseButton: .right
            )?.post(tap: .cghidEventTap)
            usleep(60_000)
        }
    }

    /// What the menu says is highlighted right now. Read while the menu is up,
    /// because `showMenu` drops its reference the moment tracking ends.
    private static func highlight() -> String? {
        guard let menu = item?.presentedMenu else { return nil }
        itemCount = menu.items.count
        return menu.highlightedItem?.title
    }

    private static func report() -> Never {
        let expectedFirst = "Show Recent Items"

        print("  Menu items        : \(itemCount)")
        print("  After one ↓       : \(afterFirst ?? "nothing highlighted")")
        print("  After two ↓       : \(afterSecond ?? "nothing highlighted")")
        print("")

        guard itemCount > 0 else {
            print("  ✗ The right click did not open the menu at all, so the")
            print("    keyboard was never the question.")
            exit(1)
        }
        guard let afterFirst else {
            print("  ✗ The first ↓ highlighted nothing. The menu is not receiving")
            print("    key events, so it cannot be used without the mouse.")
            exit(1)
        }
        guard afterFirst == expectedFirst else {
            print("  ✗ The first ↓ highlighted \"\(afterFirst)\" rather than")
            print("    \"\(expectedFirst)\". The highlight starts in the wrong place.")
            exit(1)
        }
        guard let afterSecond, afterSecond != afterFirst else {
            print("  ✗ The second ↓ did not move the highlight off")
            print("    \"\(afterFirst)\", so the menu takes the first key and then")
            print("    stops responding.")
            exit(1)
        }

        print("  ✓ ↓ moves the highlight: \"\(afterFirst)\" → \"\(afterSecond)\".")
        print("    Disabled rows and separators are stepped over, as they should be.")
        exit(0)
    }

    // MARK: - Synthesised input

    private static func step(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated(work)
        }
    }

    /// Posts a real key press through the window server, the way the user's own
    /// keyboard delivers one. `NSApp.postEvent` would put it in this process's
    /// own queue instead, which is not the path a menu is fed from and would
    /// prove the wrong thing.
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

    /// AppKit's screen coordinates put the origin at the bottom left and
    /// `CGEvent`'s put it at the top left.
    private static func flipped(_ point: CGPoint) -> CGPoint {
        let top = NSScreen.screens.map(\.frame.maxY).max()
            ?? NSScreen.main?.frame.maxY ?? 0
        return CGPoint(x: point.x, y: top - point.y)
    }
}
