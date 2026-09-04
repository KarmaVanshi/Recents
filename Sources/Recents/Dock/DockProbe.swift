import AppKit
import ApplicationServices

/// Reads the Dock through Accessibility: which tile the pointer is over, and
/// where that tile sits on screen.
///
/// There is no public notification for "the pointer entered a Dock tile" — the
/// Dock is another process and its tiles are not windows — so the only way to
/// answer the question is to ask the Dock's own accessibility tree. That makes
/// Accessibility permission a hard requirement for Dock previews, unlike the
/// deck's window captures where it merely sharpens the refresh timing.
///
/// Hit testing is done with `AXUIElementCopyElementAtPosition` rather than by
/// enumerating the tiles and comparing rectangles ourselves. With Dock
/// magnification switched on the tiles move and grow *as the pointer travels
/// over them*, so a cached table of frames is wrong the moment it is read; the
/// Dock's own hit test is right by construction. It also handles the cases a
/// naive rectangle sweep gets wrong — stacks, the Trash, the separator, and the
/// minimized-window tiles that appear on the far side of it.
///
/// Every call is bounded by an explicit messaging timeout. An AX round trip runs
/// on the calling thread and blocks it until the other process answers, and this
/// is called from a mouse-moved monitor on the main thread: a wedged Dock must
/// cost a missed preview, never a frozen cursor.
@MainActor
enum DockProbe {

    /// What a Dock tile stands for.
    enum Kind: Equatable {
        /// An application tile — the ordinary case, on the left of the separator.
        case application
        /// A single minimized window, parked on the right of the separator. Only
        /// present while "minimise windows into application icon" is off, which
        /// is the system default.
        case minimizedWindow
    }

    /// One Dock tile, as the pointer found it.
    struct Tile: Equatable {
        var kind: Kind
        /// The Dock's own label for the tile: an application name, or the title
        /// of a minimized window.
        var title: String
        /// The application bundle a tile points at. Present for application
        /// tiles; minimized-window tiles do not carry one.
        var url: URL?
        /// The tile's frame in Cocoa screen coordinates, which is what the
        /// preview panel is positioned against.
        var frame: CGRect
        /// Whether the Dock is showing this tile as running — the dot under the
        /// icon.
        ///
        /// Read from the Dock's own `AXIsApplicationRunning` rather than
        /// inferred from `NSRunningApplication`, because the dot is what the
        /// user is looking at when they decide there is something behind an
        /// icon, and the Dock is the authority on its own dot. Nil when the
        /// Dock does not answer, which the caller reads as "ask the workspace
        /// instead".
        var isRunning: Bool?

        /// Whether two readings describe the same tile.
        ///
        /// Frame is deliberately excluded. Under magnification a tile's rectangle
        /// changes continuously while the pointer crosses it, and treating that
        /// as "a different tile" would tear the preview down and rebuild it on
        /// every mouse-moved event.
        func isSameTile(as other: Tile) -> Bool {
            kind == other.kind && title == other.title && url == other.url
        }
    }

    // MARK: - Availability

    /// Dock previews cannot work without this, and there is no degraded mode:
    /// with the permission missing, `AXUIElementCopyElementAtPosition` answers
    /// `kAXErrorAPIDisabled` for every point and the pointer is never over
    /// anything at all.
    static var hasPermission: Bool { AXIsProcessTrusted() }

    // MARK: - The Dock element

    private static var cachedDock: AXUIElement?
    private static var cachedDockPID: pid_t = 0

    /// How long an AX call to the Dock may take before we give up on it.
    ///
    /// Generous by AX standards and tiny by human ones: the Dock answers a hit
    /// test in well under a millisecond when healthy, and the only thing this
    /// number governs is how long the main thread would stall if it were not.
    private static let messagingTimeout: Float = 0.25

    private static func dock() -> AXUIElement? {
        // The Dock is restarted often enough — by the user, by a display change,
        // by `killall Dock` — that holding a stale element would quietly break
        // previews until the next relaunch of this app.
        if let cachedDock,
           let running = NSRunningApplication(processIdentifier: cachedDockPID),
           !running.isTerminated {
            return cachedDock
        }

        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else { return nil }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        cachedDock = element
        cachedDockPID = app.processIdentifier
        return element
    }

    // MARK: - The tile strip

    private static var cachedStrip: CGRect?
    private static var stripReadAt: Date = .distantPast
    private static let stripLifetime: TimeInterval = 2

    /// The Dock's tile strip, in Cocoa screen coordinates.
    ///
    /// Two jobs. It is the cheap first filter for the hover watcher — the
    /// mouse-moved monitor sees every pointer movement on the system, and asking
    /// the Dock to hit test each one would be an interprocess round trip per
    /// pixel of travel, where a rectangle test rejects the overwhelming majority
    /// for nothing. And its shape is what says which screen edge the Dock is on,
    /// which decides where a preview can be put without covering the tile it
    /// belongs to.
    ///
    /// A nil answer is cached exactly like a real one. Without the permission
    /// there is no strip and never will be until it is granted, and re-asking on
    /// every mouse-moved event to be told so again is the one path here that
    /// could cost something while the feature is doing nothing.
    static func stripFrame() -> CGRect? {
        if Date().timeIntervalSince(stripReadAt) < stripLifetime { return cachedStrip }
        stripReadAt = Date()

        guard hasPermission, let dock = dock() else {
            cachedStrip = nil
            return nil
        }

        if let children: [AXUIElement] = attribute(dock, kAXChildrenAttribute),
           let list = children.first(where: { role(of: $0) == kAXListRole }),
           let axFrame = frame(of: list) {
            cachedStrip = cocoaRect(fromAX: axFrame)
        } else {
            cachedStrip = dockWindowFrame()
        }
        return cachedStrip
    }

    /// Where the Dock's own window is, asked of the window server instead of the
    /// Dock's accessibility tree.
    ///
    /// A fallback for one specific failure: the tile strip is found by looking
    /// for an `AXList` among the Dock's children, and that is a claim about the
    /// shape of another application's accessibility tree, which is not a
    /// contract Apple owes anyone. If a future Dock nests its list one level
    /// deeper, the strip would come back nil and the whole feature would go
    /// quiet — not break visibly, just never trigger, which is the worst way for
    /// something to fail. The window server's answer needs no permission and no
    /// assumption about tree shape.
    ///
    /// The size filter is what separates the tile strip from the Dock's other
    /// windows: it also owns the full-screen surface the desktop is drawn on,
    /// and a rectangle covering the whole display would send every mouse
    /// movement on the system to the accessibility hit test.
    private static func dockWindowFrame() -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let screens = NSScreen.screens.map(\.frame)

        for entry in info {
            guard entry[kCGWindowOwnerPID as String] as? pid_t == cachedDockPID,
                  let rect = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: rect as CFDictionary),
                  bounds.width > 0, bounds.height > 0,
                  !screens.contains(where: { $0.size == bounds.size })
            else { continue }
            // `kCGWindowBounds` is in the same flipped space as accessibility.
            return cocoaRect(fromAX: bounds)
        }
        return nil
    }

    /// Which screen edge the Dock is parked against.
    ///
    /// Read from the strip's own shape rather than from the Dock's preferences:
    /// a tall narrow strip is a side Dock and a wide short one is along the
    /// bottom, whatever `com.apple.dock` last wrote to disk, and which side is
    /// then simply which half of its display it sits in. Defaults to the bottom,
    /// which is both the system default and the harmless answer — a preview
    /// placed above a side Dock is merely in an odd place, not on top of the
    /// tile it describes.
    enum Edge {
        case bottom, left, right
    }

    static func edge() -> Edge {
        guard let strip = stripFrame() else { return .bottom }
        guard strip.height > strip.width else { return .bottom }
        let screen = NSScreen.screens.first { $0.frame.intersects(strip) } ?? NSScreen.main
        guard let screen else { return .left }
        return strip.midX < screen.frame.midX ? .left : .right
    }

    /// Forces the next `stripFrame()` to re-read. Called when the screen
    /// arrangement changes, which is one of the two ways the Dock moves without
    /// anything else telling us.
    static func invalidateStrip() {
        cachedStrip = nil
        stripReadAt = .distantPast
    }

    // MARK: - Hit testing

    /// The Dock tile under a point given in Cocoa screen coordinates, or nil
    /// when the point is over the Dock's background, over a tile this app has
    /// nothing to say about — the separator, the Trash, a stack — or over
    /// something that is not the Dock at all.
    static func tile(at point: CGPoint) -> Tile? {
        guard hasPermission, let dock = dock() else { return nil }

        let position = axPoint(fromCocoa: point)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            dock, Float(position.x), Float(position.y), &found
        ) == .success, let element = found else { return nil }

        guard role(of: element) == "AXDockItem",
              let subrole: String = attribute(element, kAXSubroleAttribute),
              let kind = Kind(subrole: subrole),
              let axFrame = frame(of: element)
        else { return nil }

        return Tile(
            kind: kind,
            title: attribute(element, kAXTitleAttribute) ?? "",
            url: url(of: element),
            frame: cocoaRect(fromAX: axFrame),
            // Not a documented constant: the Dock publishes this on its
            // application items and on nothing else, which is exactly the
            // distinction wanted here.
            isRunning: attribute(element, "AXIsApplicationRunning")
        )
    }

    // MARK: - Attribute reading

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? T
    }

    private static func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute)
    }

    /// `AXURL` comes back as a `CFURL`, which bridges to `NSURL` rather than to
    /// `URL` directly.
    private static func url(of element: AXUIElement) -> URL? {
        let value: NSURL? = attribute(element, kAXURLAttribute)
        return value as URL?
    }

    /// Position and size are `AXValue` boxes rather than plain numbers, and the
    /// type is checked before unwrapping — an element that answers the attribute
    /// with something else would otherwise be a crash rather than a miss.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let rawPosition = positionValue, CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = sizeValue, CFGetTypeID(rawSize) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    // MARK: - Coordinate spaces

    /// Accessibility measures from the top-left of the primary display with y
    /// growing downwards; Cocoa measures from its bottom-left with y growing up.
    /// Every rectangle crossing between the two has to be flipped about the
    /// primary display's height — not the height of whichever display the tile
    /// happens to be on, which is the mistake that puts previews on the wrong
    /// screen in a mixed-resolution arrangement.
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    private static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX, y: primaryHeight - rect.maxY,
            width: rect.width, height: rect.height
        )
    }

    private static func axPoint(fromCocoa point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

private extension DockProbe.Kind {
    /// The Dock's other subroles — the separator, the Trash, stacks, and plain
    /// file or URL tiles — have no windows behind them, so there is nothing for
    /// a preview to show and they map to nil rather than to a case.
    init?(subrole: String) {
        switch subrole {
        case "AXApplicationDockItem": self = .application
        case "AXMinimizedWindowDockItem": self = .minimizedWindow
        default: return nil
        }
    }
}
