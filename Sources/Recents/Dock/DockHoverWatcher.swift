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
/// Cost is kept off the common path deliberately. The tap sees every pointer
/// movement on the system, so the first thing each event does is a rectangle
/// test against the Dock's strip — no interprocess traffic, no allocation. Only
/// a pointer actually inside the Dock reaches the accessibility hit test, and
/// even then no faster than `hitTestInterval`.
///
/// Mouse events are used rather than polling because they cost nothing when the
/// pointer is still, which is most of the time. They come from a listen-only
/// `CGEvent` tap rather than `NSEvent`'s global monitor, and the difference is
/// not a matter of taste. While this process held a global monitor for
/// mouse-moved events, the window server all but stopped delivering mouse-moved
/// events to this app's own preview panel: `DockSweepSelfTest` measured five
/// reaching the panel across a sweep that put a hundred and ninety on the
/// system, the rest arriving at the *global* monitor as though the panel were
/// some other application's window — so the highlight sat on one thumbnail
/// while the pointer crossed the other two. With a session tap in its place the
/// panel receives every event the display refresh allows, and the tap sees the
/// ones over this app's windows as well, which the monitor never did.
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

    /// Whether the consumer currently has a preview on screen. Set by whoever
    /// consumes `onTile`.
    ///
    /// A pointer that has settled on one tile and then moves to the next is
    /// browsing, not passing through, and there is no dwell at all in that
    /// state: the next tile is reported the moment the pointer is on it. The
    /// strobing the dwell exists to prevent is the thing the user is now doing
    /// on purpose — the taskbar on Windows switches thumbnails instantly in the
    /// same state, and the Dock's own labels follow the pointer tile by tile —
    /// and a short chained dwell measured as nothing but lag: 40 ms of waiting
    /// in front of 8 ms of work, on every tile.
    var isShowingPreview = false {
        didSet {
            if oldValue && !isShowingPreview { browsingUntil = Date().addingTimeInterval(browsingGrace) }
        }
    }

    /// How long after a preview goes the pointer still counts as browsing.
    ///
    /// The tiles along a Dock are mostly not running, and a preview crossing
    /// one of them is dismissed — there is nothing to show for it. Without this
    /// the next running tile would then be back to the full dwell, and walking
    /// along a mixed Dock would alternate between instant and slow. Long enough
    /// to cross a few idle tiles, short enough that a preview dismissed by
    /// leaving the Dock does not come back instantly on a later, unrelated pass.
    private let browsingGrace: TimeInterval = 0.4
    private var browsingUntil: Date = .distantPast

    private var isBrowsing: Bool { isShowingPreview || Date() < browsingUntil }

    /// Floor on how often the Dock is asked what is under the pointer. Once a
    /// frame is finer than the dwell it feeds — a hit test must never be the
    /// reason a preview is late — and it still bounds the interprocess traffic a
    /// fast drag across the Dock can generate. A movement that lands inside the
    /// window is held until the window ends rather than dropped, so the last
    /// movement before the pointer comes to rest — the one that says where it
    /// stopped — is always tested.
    private let hitTestInterval: TimeInterval = 0.016

    /// Movement below this is treated as the pointer standing still. Optical
    /// mice jitter by a point or two at rest, which would otherwise re-run the
    /// hit test forever for a pointer that has not gone anywhere.
    private let movementThreshold: CGFloat = 1.5

    /// How far outside the reported strip a pointer still counts as being over
    /// the Dock. See the note at the test itself.
    private static let stripPadding: CGFloat = 64

    // MARK: - State

    /// The mouse-moved tap and the click monitor. See `start`.
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var monitors: [Any] = []
    private var lastHitTest: Date = .distantPast
    private var lastPoint: CGPoint = .zero

    /// A hit test held back by `hitTestInterval`, to run when the window ends.
    private var deferredHitTest: Timer?

    /// The tile the pointer is over but has not yet held long enough, and when
    /// it arrived there.
    private var pending: (tile: DockProbe.Tile, since: Date)?

    /// The tile last reported through `onTile`, so a repeat is not reported.
    private var reported: DockProbe.Tile?

    /// A tile the user has just clicked, which is not reported again until the
    /// pointer has left it.
    ///
    /// A click on a tile launches or raises something, and the pointer is
    /// usually still resting on the tile while that happens. Without this the
    /// next point or two of jitter began a fresh dwell and put the preview
    /// straight back up — over the very window the click had just brought
    /// forward. The suppression ends when the pointer moves onto a different
    /// tile or off the Dock, which is the user saying they are done with it.
    private var suppressed: DockProbe.Tile?

    /// Fires while the pointer is standing on a tile that has not yet been held
    /// long enough. Mouse-moved events cannot deliver the dwell on their own: a
    /// pointer that stops moving stops generating them, which is precisely the
    /// case a dwell is meant to detect.
    private var dwellTimer: Timer?

    private var screenObserver: NSObjectProtocol?

    private init() {}

    var isRunning: Bool { tap != nil || !monitors.isEmpty }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        // Listen-only, and on the main run loop, so the callback is on the
        // thread everything else here runs on. A tap for pointer movement needs
        // Accessibility, which reading the Dock needs anyway; refused, there is
        // no pointer to watch and the feature is quietly off, exactly as it is
        // without the Dock.
        let callback: CGEventTapCallBack = { _, type, event, _ in
            MainActor.assumeIsolated {
                let watcher = DockHoverWatcher.shared
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    // The system switches a tap off if its callback ever runs
                    // long, and says so by sending it this. Left off, previews
                    // would stop for the rest of the session the first time
                    // the machine was briefly busy.
                    if let tap = watcher.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                default:
                    watcher.pointerMoved(to: NSEvent.mouseLocation)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
            callback: callback,
            userInfo: nil
        ) {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.tap = tap
            tapSource = source
        }

        // Clicks stay on a global monitor: a click on a Dock tile is aimed at
        // another process, which is exactly what a monitor sees, and a monitor
        // for mouse *down* has shown none of the mouse-moved trouble above.
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
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        cancelDeferredHitTest()
        cancelDwell()
        pending = nil
        suppressed = nil
        if reported != nil {
            reported = nil
            onTile?(nil)
        }
    }

    // MARK: - Events

    private func clicked() {
        // Whichever tile the pointer was on — settled or still dwelling — is the
        // one the click was aimed at.
        suppressed = reported ?? pending?.tile
        pending = nil
        cancelDeferredHitTest()
        cancelDwell()
        if reported != nil {
            reported = nil
            onTile?(nil)
        }
        onClick?()
        // A click is the user done browsing: the next tile earns its preview
        // with a full dwell again. After the callback, which hides the panel
        // and would otherwise re-arm the grace on the way out.
        browsingUntil = .distantPast
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

        let sinceLast = Date().timeIntervalSince(lastHitTest)
        guard sinceLast >= hitTestInterval else {
            deferHitTest(by: hitTestInterval - sinceLast)
            return
        }
        hitTest(at: point)
    }

    private func deferHitTest(by delay: TimeInterval) {
        guard deferredHitTest == nil else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                let watcher = DockHoverWatcher.shared
                watcher.deferredHitTest = nil
                // Where the pointer is now, not where it was when the movement
                // was held back.
                watcher.hitTest(at: NSEvent.mouseLocation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deferredHitTest = timer
    }

    private func cancelDeferredHitTest() {
        deferredHitTest?.invalidate()
        deferredHitTest = nil
    }

    private func hitTest(at point: CGPoint) {
        cancelDeferredHitTest()
        lastHitTest = Date()

        guard let tile = DockProbe.tile(at: point) else {
            leaveTile()
            return
        }

        // Still on the tile that was just clicked: nothing to report. Any other
        // tile ends the suppression.
        if let suppressed {
            guard !suppressed.isSameTile(as: tile) else { return }
            self.suppressed = nil
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

        // A new tile, with the pointer browsing: reported at once, and as a
        // straight switch rather than a leave followed by an arrival, so the
        // consumer replaces one preview with the next instead of being told
        // there is nothing and then that there is something.
        if isBrowsing {
            pending = nil
            cancelDwell()
            reported = tile
            onTile?(tile)
            return
        }

        // A new tile, from cold. Anything already on screen is for a different
        // tile and is now wrong, so it goes at once rather than at the end of
        // the new dwell.
        if reported != nil {
            reported = nil
            onTile?(nil)
        }
        pending = (tile, Date())
        startDwell()
    }

    private func leaveTile() {
        pending = nil
        suppressed = nil
        cancelDeferredHitTest()
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
        guard let current = DockProbe.tile(at: NSEvent.mouseLocation) else {
            self.pending = nil
            return
        }

        // On a different tile than the one the dwell was started for: that tile
        // begins its own dwell, exactly as it would have had the movement onto
        // it been seen. Giving up here instead left nothing pending and nothing
        // coming — a pointer at rest sends no more events — so a tile reached
        // just as the previous dwell ran out never got its preview at all.
        guard current.isSameTile(as: pending.tile) else {
            self.pending = (current, Date())
            startDwell()
            return
        }

        self.pending = nil
        reported = current
        onTile?(current)
    }
}
