import AppKit

/// Watches the pointer for a deliberate hover over a Dock tile.
///
/// The signal this turns into is "the user is looking at *this* tile" rather
/// than "the pointer touched this tile", and the difference is the whole
/// usability of the feature. A pointer travelling to the Trash crosses six
/// application tiles on the way; showing a preview for each would be a strobe
/// light. So a tile has to be held for `dwell` before it is reported, exactly as
/// the Dock does before showing its own name label.
///
/// Cost is kept off the common path deliberately. A global mouse-moved monitor
/// sees every pointer movement on the system, so the first thing each event does
/// is a rectangle test against the Dock's strip — no interprocess traffic, no
/// allocation. Only a pointer actually inside the Dock reaches the accessibility
/// hit test, and even then no faster than `hitTestInterval`.
///
/// Mouse events are used rather than polling because they cost nothing when the
/// pointer is still, which is most of the time. Note that they stop arriving
/// while the pointer is over one of this app's own windows — a global monitor
/// only sees events destined for *other* processes — so whoever consumes this
/// is responsible for noticing the pointer entering its own panel.
@MainActor
final class DockHoverWatcher {

    static let shared = DockHoverWatcher()

    /// The tile the pointer is settled on, or nil when it is not on one.
    ///
    /// Called on every change, never repeatedly for the same tile.
    var onTile: ((DockProbe.Tile?) -> Void)?

    /// The user clicked, anywhere. A click on the Dock is about to launch,
    /// raise or minimise something, and a preview of the old state hanging over
    /// it is in the way.
    var onClick: (() -> Void)?

    // MARK: - Tuning

    /// How long a tile must be held before it counts as a hover.
    ///
    /// Short enough to feel like a property of the icon rather than a thing that
    /// has to be waited for, long enough that a pointer travelling to the Trash
    /// across six tiles does not fire six previews on the way. An eighth of a
    /// second is comfortably under the ~200 ms at which a response stops reading
    /// as immediate, and comfortably over the time a pointer spends crossing a
    /// tile it is not aiming at.
    private let dwell: TimeInterval = 0.12

    /// Floor on how often the Dock is asked what is under the pointer. Forty a
    /// second is finer than the dwell it feeds — a hit test must never be the
    /// reason a preview is late — and it still bounds the interprocess traffic a
    /// fast drag across the Dock can generate.
    private let hitTestInterval: TimeInterval = 0.025

    /// Movement below this is treated as the pointer standing still. Optical
    /// mice jitter by a point or two at rest, which would otherwise re-run the
    /// hit test forever for a pointer that has not gone anywhere.
    private let movementThreshold: CGFloat = 1.5

    /// How far outside the reported strip a pointer still counts as being over
    /// the Dock. See the note at the test itself.
    private static let stripPadding: CGFloat = 64

    // MARK: - State

    private var monitors: [Any] = []
    private var lastHitTest: Date = .distantPast
    private var lastPoint: CGPoint = .zero

    /// The tile the pointer is over but has not yet held long enough, and when
    /// it arrived there.
    private var pending: (tile: DockProbe.Tile, since: Date)?

    /// The tile last reported through `onTile`, so a repeat is not reported.
    private var reported: DockProbe.Tile?

    /// Fires while the pointer is standing on a tile that has not yet been held
    /// long enough. Mouse-moved events cannot deliver the dwell on their own: a
    /// pointer that stops moving stops generating them, which is precisely the
    /// case a dwell is meant to detect.
    private var dwellTimer: Timer?

    private var screenObserver: NSObjectProtocol?

    private init() {}

    var isRunning: Bool { !monitors.isEmpty }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        let moved = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved],
            handler: { _ in
                MainActor.assumeIsolated {
                    DockHoverWatcher.shared.pointerMoved(to: NSEvent.mouseLocation)
                }
            }
        )
        if let moved { monitors.append(moved) }

        let clicked = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { _ in
                MainActor.assumeIsolated { DockHoverWatcher.shared.clicked() }
            }
        )
        if let clicked { monitors.append(clicked) }

        // A display being attached, removed or rearranged moves the Dock without
        // any pointer movement to notice it by, and the cached strip rectangle
        // would go on rejecting every event over the Dock's new position.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DockProbe.invalidateStrip() }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        cancelDwell()
        pending = nil
        if reported != nil {
            reported = nil
            onTile?(nil)
        }
    }

    // MARK: - Events

    private func clicked() {
        pending = nil
        cancelDwell()
        if reported != nil {
            reported = nil
            onTile?(nil)
        }
        onClick?()
    }

    private func pointerMoved(to point: CGPoint) {
        guard abs(point.x - lastPoint.x) + abs(point.y - lastPoint.y) >= movementThreshold
        else { return }
        lastPoint = point

        // The cheap rejection, run on every one of these events. A pointer
        // nowhere near the Dock ends here, having touched nothing but a
        // rectangle.
        //
        // The strip is grown before the test rather than used as reported,
        // because this has to over-include rather than under-include:
        // magnification lifts a tile clear of the strip the accessibility tree
        // describes, and an autohidden Dock is reported where it will be rather
        // than where it currently is. Either would put a real hover outside the
        // rectangle and the preview would simply never appear. Over-including
        // costs one throttled hit test that comes back empty.
        guard let strip = DockProbe.stripFrame(),
              strip.insetBy(dx: -Self.stripPadding, dy: -Self.stripPadding).contains(point)
        else {
            leaveTile()
            return
        }

        guard Date().timeIntervalSince(lastHitTest) >= hitTestInterval else { return }
        lastHitTest = Date()

        guard let tile = DockProbe.tile(at: point) else {
            leaveTile()
            return
        }

        // Already reported and unchanged: nothing to do but keep the frame
        // up to date, since the panel is positioned against it and magnification
        // moves it under the pointer.
        if let reported, reported.isSameTile(as: tile) {
            self.reported = tile
            return
        }

        if let pending, pending.tile.isSameTile(as: tile) {
            self.pending = (tile, pending.since)
            return
        }

        // A new tile. Anything already on screen is for a different tile and is
        // now wrong, so it goes at once rather than at the end of the new dwell.
        if reported != nil {
            reported = nil
            onTile?(nil)
        }
        pending = (tile, Date())
        startDwell()
    }

    private func leaveTile() {
        pending = nil
        cancelDwell()
        guard reported != nil else { return }
        reported = nil
        onTile?(nil)
    }

    // MARK: - Dwell

    private func startDwell() {
        cancelDwell()
        let timer = Timer.scheduledTimer(withTimeInterval: dwell, repeats: false) { _ in
            MainActor.assumeIsolated { DockHoverWatcher.shared.dwellElapsed() }
        }
        // Common modes: the Dock is exactly the sort of place a pointer goes
        // while a menu is open or a window is mid-drag, and a run loop parked in
        // one of those modes would swallow this.
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    private func dwellElapsed() {
        dwellTimer = nil
        guard let pending else { return }

        // Re-read rather than trusting the tile recorded at the start of the
        // dwell. The pointer can have moved during it without generating an
        // event this watcher saw — a Space switch, a window opening under the
        // cursor — and reporting a tile the pointer has since left would show a
        // preview attached to nothing.
        guard let current = DockProbe.tile(at: NSEvent.mouseLocation),
              current.isSameTile(as: pending.tile)
        else {
            self.pending = nil
            return
        }

        self.pending = nil
        reported = current
        onTile?(current)
    }
}
