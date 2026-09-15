import AppKit
import Combine
import SwiftUI

/// The panel a Dock preview lives in.
///
/// Non-activating and never key. Hovering the Dock must not take focus from
/// whatever the user is working in — the whole gesture is "glance without
/// committing" — and a panel that stole key status would make looking at a
/// window preview more disruptive than switching to the window itself.
///
/// Borderless, because it has no chrome to draw: it is positioned by the pointer,
/// dismissed by the pointer, and has nothing to aim at. The rounded corners and
/// the material come from `DeckBackgroundView`, the same background the deck
/// window is built on, so the preview is visibly a piece of the same app.
final class DockPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that answers the first click, and reports where the pointer is.
///
/// A window that is not key normally swallows the click that would have made it
/// key, so the user has to click a thumbnail twice: once to focus a panel that
/// refuses focus, and once for the thumbnail. Since this panel never becomes
/// key, that first click has nothing to do but be delivered.
///
/// The pointer is tracked here, in AppKit, rather than with SwiftUI's `onHover`
/// on each thumbnail. In a window that can never become key, SwiftUI's hover
/// fires when the pointer enters the panel and then ignores every mouse-moved
/// event after it — this view was measured receiving all of them while the
/// highlight stayed on the first thumbnail the pointer had crossed. A tracking
/// area of our own is delivered to regardless of key or active status, and the
/// controller turns each position into a thumbnail through the same layout
/// that placed them. See `DockPreviewLayout.thumbnailIndex(at:)`.
private final class DockPreviewHostingView<Content: View>: NSHostingView<Content> {

    /// Where the pointer is over this view, measured down and right from its
    /// top-left corner, or nil once it has left.
    var onPointer: ((CGPoint?) -> Void)?

    private var pointerArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointer?(location(of: event))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?(location(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(nil)
    }

    /// Where the pointer is right now, in the same coordinates, or nil when it
    /// is not over this view. For the moment a row is installed under a
    /// pointer that is already resting on it: AppKit does not promise an
    /// enter for a tracking area created under a stationary cursor.
    var pointerLocation: CGPoint? {
        guard let window else { return nil }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        guard bounds.contains(point) else { return nil }
        return topLeft(point)
    }

    private func location(of event: NSEvent) -> CGPoint {
        topLeft(convert(event.locationInWindow, from: nil))
    }

    private func topLeft(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
    }
}

/// Shows a live preview of an application's windows while the pointer rests on
/// its Dock tile.
///
/// Everything here is arranged around one rule: the preview belongs to the
/// pointer. It appears where the pointer is, it follows the pointer between
/// tiles, and it leaves as soon as the pointer commits to something else. The
/// only state it keeps is which tile it is currently showing.
///
/// Dismissal is the part that needs care, and it is deliberately not driven by
/// mouse events alone. A pointer that has come to rest sends no more of them,
/// and "the pointer has been off the tile and the panel for a while" is a fact
/// about where it is resting, not about where it last moved. A slow poll while
/// the panel is on screen answers that, and costs nothing the rest of the time
/// because it does not run.
@MainActor
final class DockPreviewController {

    static let shared = DockPreviewController()

    private var panel: DockPreviewPanel?
    private var background: DeckBackgroundView?

    /// The tile the panel currently describes, and the geometry it was placed
    /// against.
    private var shownTile: DockProbe.Tile?
    private var shownFrame: CGRect = .zero

    /// What the panel is currently showing, so the keys have something to act
    /// on. The row's length is what bounds the arrow keys, and the target is
    /// what Return opens when the row is a remembered still with no window
    /// behind it.
    private var shownTarget: DockWindows.Target?

    /// The highlighted thumbnail, shared by the pointer and the arrow keys.
    private let selection = DockPreviewSelection()

    /// The thumbnail the pointer was last resolved to, or nil when it is over
    /// none — the header, a gap, the padding, or off the panel.
    ///
    /// Kept so the pointer only speaks when *that* changes. Every mouse-moved
    /// event resolves to a thumbnail or to nothing, and acting on each one
    /// would have a pointer resting on the panel's margin clear the highlight
    /// the arrow keys had just put down, on every point of jitter — which is
    /// exactly what `DockKeySelfTest` does while it presses them.
    private var pointerIndex: Int?

    /// How the row on screen was sized. Built here and handed to the view, so
    /// the panel's geometry has one definition — which is what lets
    /// `DockCloseSelfTest` aim at a thumbnail's close button instead of
    /// reconstructing where it probably went.
    private(set) var shownLayout: DockPreviewLayout?

    /// Reads the arrow keys while a preview is up. See `DockPreviewKeys` for
    /// why this is a tap rather than a monitor.
    private let keys = DockPreviewKeys()

    private var pollTimer: Timer?
    /// When the pointer left both the tile and the panel, or nil while it is
    /// still on one of them.
    private var awaySince: Date?

    private var screenObserver: NSObjectProtocol?

    /// What the last close attempt from a thumbnail did, and how many have been
    /// made. Every failure on that path is silent from outside — see
    /// `DockWindows.CloseOutcome` — so the self test reads these rather than
    /// guessing from whether a window happened to disappear.
    private(set) static var closeAttempts = 0
    private(set) static var lastCloseOutcome: DockWindows.ActionOutcome?

    /// How long the pointer may be off both the tile and the panel before the
    /// preview goes.
    ///
    /// Long enough to cross the gap between them without the panel vanishing
    /// mid-reach, short enough that a preview never lingers over something the
    /// user has moved on from.
    private let grace: TimeInterval = 0.22

    /// How often the pointer is checked while the panel is up. Ten a second is
    /// imperceptible against a 0.22s grace period and is the entire cost of this
    /// object while it is visible.
    private let pollInterval: TimeInterval = 0.1

    /// Distance between the tile and the panel.
    private let gap: CGFloat = 14

    /// Keep-out margin from the edge of the usable screen.
    private let margin: CGFloat = 8

    private init() {
        keys.onKey = { [weak self] key in
            MainActor.assumeIsolated { self?.handle(key) ?? false }
        }
    }

    // MARK: - Lifecycle

    var isEnabled: Bool { Preferences.shared.dockPreviews }

    /// Whether the feature can actually do anything on this machine right now.
    /// Both permissions are genuinely required and neither degrades: without
    /// Accessibility the Dock cannot be asked what the pointer is over, and
    /// without Screen Recording the window server returns no pixels.
    static var isSupported: Bool { WindowServerCapture.isAvailable }

    /// Whether this object has installed its watcher and its observer.
    ///
    /// Its own state, rather than `DockHoverWatcher.shared.isRunning` read as a
    /// proxy for it. The watcher's monitors can decline to install, and a false
    /// answer from over there sent `start()` through its body again on every
    /// preference change — re-registering `screenObserver` over the top of the
    /// last one, which is then never removed.
    private var isStarted = false

    func start() {
        guard isEnabled, !isStarted else { return }
        isStarted = true

        let watcher = DockHoverWatcher.shared
        watcher.onTile = { [weak self] tile in
            MainActor.assumeIsolated { self?.hovered(tile) }
        }
        watcher.onClick = { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        watcher.start()

        // A display change moves the Dock and can move the screen the panel is
        // sitting on out from under it. Cheaper to dismiss and let the next
        // hover place it correctly than to try to re-derive where it should go.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }

        // Once launch is out of the way rather than in its path.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.warmUp() }
        }
    }

    /// Builds the panel and one throwaway row before the first hover asks for
    /// them.
    ///
    /// The first `show` of a session was measured at ~85 ms against ~7 ms for
    /// every one after it: creating the panel and its material, and SwiftUI
    /// standing up its first hosting view, fonts and glass surfaces. Paid here,
    /// in idle time just after launch, it is invisible; paid on the first hover
    /// it was the one preview that visibly took longer than the rest. Nothing is
    /// ordered on screen and nothing is subscribed to the feed — the row is a
    /// single blank still, built, measured and thrown away.
    private func warmUp() {
        guard isStarted, panel == nil else { return }
        let panel = makePanel()
        self.panel = panel
        applyAppearance()

        let still = AppWindowCapture.Capture(
            image: NSImage(size: NSSize(width: 16, height: 10)),
            capturedAt: .distantPast, windowTitle: nil,
            sourceSize: CGSize(width: 16, height: 10),
            pixelSize: CGSize(width: 16, height: 10),
            documentURL: nil
        )
        let target = DockWindows.Target(
            name: "", bundleID: "", applicationURL: nil,
            windows: [], totalWindows: 0, still: still, document: nil
        )
        let layout = DockPreviewLayout(
            sourceSizes: DockPreviewView.sourceSizes(for: target), availableWidth: 1280
        )
        let hosting = DockPreviewHostingView(rootView: DockPreviewView(
            target: target, slots: [:], selection: DockPreviewSelection(),
            layout: layout, icon: nil,
            onActivate: { _ in false }, onClose: { _ in false }, onZoom: { _ in false },
            onOpen: { false }
        ))
        let size = hosting.fittingSize
        hosting.translatesAutoresizingMaskIntoConstraints = false
        install(hosting)
        // Drawn once, off any screen, so the window's backing store exists
        // before the first placement asks for it.
        panel.setFrame(NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), display: true)
        hosting.removeFromSuperview()

        // The first event tap of a session is the expensive one — measured at
        // 16 ms against nothing for every one after it. Binding the capture
        // SPI and the first walk of the window list are cold once each, too.
        keys.start()
        keys.stop()
        _ = WindowServerCapture.isAvailable
        _ = WindowServerCapture.candidateWindows()
        LiveWindowPreview.shared.warmUp()
    }

    func stop() {
        isStarted = false
        let watcher = DockHoverWatcher.shared
        watcher.stop()
        watcher.onTile = nil
        watcher.onClick = nil

        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        hide()
    }

    /// Applies a change to the preference without waiting for a relaunch, so the
    /// switch can be judged from the Settings window the user is standing in.
    func reload() {
        if isEnabled { start() } else { stop() }
    }

    // MARK: - Hovering

    private func hovered(_ tile: DockProbe.Tile?) {
        guard let tile else {
            // Not hidden outright: the pointer leaving a tile is usually the
            // pointer on its way *into* the panel, across the gap between them.
            // The poll decides, because only it can see where the pointer went.
            beginGrace()
            return
        }

        // The same tile, re-reported because magnification moved it under the
        // pointer. The recorded frame is updated, because the region that counts
        // as "still hovering" is measured from it — but the panel deliberately
        // stays where it was put. Following a magnifying tile would make the
        // preview slide about under a hand that is only trying to reach it, and
        // the placement it already has was made against the tile at full
        // magnification, which is the size it has while the pointer is on it.
        if let shownTile, shownTile.isSameTile(as: tile) {
            self.shownTile = tile
            awaySince = nil
            return
        }

        guard let target = DockWindows.target(for: tile) else {
            hide()
            return
        }

        show(target, for: tile)
    }

    private func beginGrace() {
        guard panel?.isVisible == true else { return }
        if awaySince == nil { awaySince = Date() }
    }

    /// Which thumbnail is currently highlighted, by position in the row.
    ///
    /// The one piece of the panel's state worth reading from outside: it is what
    /// the arrow keys move and what Return acts on, and `DockKeySelfTest` has no
    /// other way to ask whether a keystroke arrived.
    var selectedIndex: Int? { selection.index }

    /// Every change to the highlight, as it happens.
    ///
    /// For `DockSweepSelfTest`, which measures how far the highlight runs
    /// behind a pointer sweeping the row: the instant `select` writes the index
    /// is one end of that measurement, and nothing polled from outside could
    /// place it — a poll on the main thread is delayed by the very stalls being
    /// measured.
    var selectionChanges: AnyPublisher<Int?, Never> {
        selection.$index.dropFirst().eraseToAnyPublisher()
    }

    /// Puts a preview on screen as though its tile had been hovered, and leaves
    /// it there.
    ///
    /// The self-test's only way in. Everything else in this object is driven by
    /// the pointer, and a test that reached around that to build its own panel
    /// would be testing a copy of the code rather than the code. Returns the
    /// panel's window number so the test can photograph exactly that window
    /// rather than the screen it happens to be on.
    func showForSelfTest(_ tile: DockProbe.Tile) -> Int? {
        guard let target = DockWindows.target(for: tile) else { return nil }
        show(target, for: tile)
        // There is no pointer following this one, so the dismissal poll would
        // take it away again within the grace period.
        stopPolling()
        return panel?.windowNumber
    }

    // MARK: - Showing

    /// - Parameter keepingSelection: whether this is the same row re-forming
    ///   rather than a different tile's. See where the selection is set below.
    private func show(
        _ target: DockWindows.Target, for tile: DockProbe.Tile,
        keepingSelection: Bool = false
    ) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        applyAppearance()

        let layout = DockPreviewLayout(
            sourceSizes: DockPreviewView.sourceSizes(for: target),
            availableWidth: availableWidth(for: tile)
        )
        shownLayout = layout

        // The panel's subscriptions belong to the panel, and are registered here
        // by the object that owns it.
        //
        // They used to be registered by each thumbnail from `onAppear` and
        // dropped from `onDisappear`, which ties a subscription's life to a
        // SwiftUI event whose ordering against this rebuild is not something to
        // depend on. When the outgoing hierarchy's `onDisappear` ran *after* the
        // incoming one's `onAppear` — hovering back to a tile just left, or
        // re-forming the panel after a close, where both hierarchies name the
        // same window — it dropped the demand that had just been registered. The
        // thumbnail then showed its priming frame and never refreshed again,
        // which is indistinguishable from a still: it is what "the Dock preview
        // is not live" was.
        //
        // Tied to the panel's own lifetime instead. Everything it is about to
        // show is subscribed before the hierarchy exists, and `hide` drops the
        // lot, so no SwiftUI ordering can take a live thumbnail off the feed.
        let engine = LiveWindowPreview.shared
        engine.clearWindowDemands()

        // Every window in the row at the full rate, not just whichever one the
        // pointer happens to be over.
        //
        // The `.visible` tier describes something on the edge of what is being
        // looked at — a card three places along the deck's rail — and nothing in
        // this panel is that. The panel exists for exactly as long as the user is
        // watching it and holds six thumbnails at most, all of them on screen
        // together, so subscribing the unhovered ones at a fifth of the rate
        // meant the panel opened as five stills and one live picture. Measured at
        // 3 captures a second against 15, which for a window whose content is
        // mostly still is no new frames at all: the preview was live only under
        // the pointer, which is the one place a preview is least needed.
        //
        // `maximumPerTick` still bounds what this can cost — six windows share
        // the tick budget and land at ten frames a second each, which is live.
        var slots: [CGWindowID: LiveWindowPreview.Slot] = [:]
        for window in target.windows {
            slots[window.id] = engine.slot(forWindow: window.id)
            engine.setDemand(.focused, forWindow: window.id)
        }

        // A new row is a new set of things to choose between, so nothing is
        // carried over: index 1 of the previous tile's windows means nothing
        // here. Set before the hierarchy is built, so it opens with no
        // highlight rather than flashing the old one.
        //
        // The same row re-forming is the exception, and it is why this is a
        // parameter rather than an unconditional clear. Closing a window from a
        // thumbnail rebuilds the panel around what is left while the pointer has
        // not moved at all; clearing the highlight there takes the cross out from
        // under a pointer that is still resting on a picture, and AppKit does not
        // promise a fresh `mouseEntered` for a tracking area created under a
        // stationary cursor — so closing a second window took a deliberate jiggle
        // of the mouse, which is precisely what keeping the panel up after a
        // close was meant to save.
        shownTarget = target
        if !keepingSelection { selection.index = nil }
        clampSelection()

        let root = DockPreviewView(
            target: target,
            slots: slots,
            selection: selection,
            layout: layout,
            icon: DockPreviewView.icon(for: target),
            onActivate: { [weak self] window in
                MainActor.assumeIsolated {
                    // A window that cannot be reached through Accessibility
                    // falls back to asking its application to open one — see
                    // `DockWindows.activateOrOpen`. Either way the click led
                    // somewhere, so the panel goes; the thumbnail's badge is now
                    // only for the tile that has no application to ask.
                    guard DockWindows.activateOrOpen(window: window, of: target) else {
                        return false
                    }
                    self?.hide()
                    return true
                }
            },
            onClose: { [weak self] window in
                MainActor.assumeIsolated {
                    Self.closeAttempts += 1
                    let outcome = DockWindows.close(window: window)
                    Self.lastCloseOutcome = outcome
                    guard outcome.isSuccess else {
                        // Nothing was asked to close, so there is nothing to
                        // re-form around. Rebuilding here would also throw away
                        // the thumbnail's own record of having failed, which is
                        // the only thing telling the user why their click did
                        // nothing.
                        return false
                    }
                    // The preview stays up and re-forms around what is left.
                    // Closing one of four windows is not a decision to stop
                    // looking at the other three, and dismissing the panel would
                    // make closing a second one take another hover.
                    // Before the rebuild, so the window can actually leave the
                    // window server's list — see `forgetWindow`.
                    engine.forgetWindow(window.id)
                    self?.forget(window)
                    self?.rebuildAfterClosing(window)
                    return true
                }
            },
            onZoom: { [weak self] window in
                MainActor.assumeIsolated {
                    // Only the part that can be settled at once decides whether
                    // the panel goes. A window that had to be restored is still
                    // coming back, and a panel held open over it waiting for the
                    // maximise to land would be sitting on top of the window the
                    // user just asked to see.
                    guard DockWindows.zoom(window: window).isSuccess else {
                        return false
                    }
                    self?.hide()
                    return true
                }
            },
            onOpen: { [weak self] in
                MainActor.assumeIsolated {
                    guard DockWindows.open(target) else { return false }
                    self?.hide()
                    return true
                }
            }
        )

        let hosting = DockPreviewHostingView(rootView: root)
        hosting.onPointer = { [weak self] point in
            MainActor.assumeIsolated { self?.pointer(at: point) }
        }

        // Ask the built hierarchy how big it wants to be rather than computing
        // it here in parallel. Every dimension in the row is fixed at build time
        // — thumbnail heights, widths derived from each window's aspect ratio —
        // so this is exact, and it stays exact if the layout is ever changed.
        //
        // Measured before the view is installed, while it is still free-standing.
        // Once it is pinned to all four edges of the background its fitting size
        // is entangled with whatever size the panel happens to have left over
        // from the previous hover.
        let size = hosting.fittingSize

        guard size.width > 1, size.height > 1 else {
            // Nothing to show, and a zero-sized panel would be an invisible
            // window left on screen holding the feed open. Answered before the
            // view is installed rather than after: a hierarchy parented to a
            // panel that is then abandoned holds its thumbnails' slots, and a
            // slot holds the window's backing store — see `forgetWindow`.
            hide()
            return
        }

        hosting.translatesAutoresizingMaskIntoConstraints = false
        install(hosting)

        shownTile = tile
        awaySince = nil
        // From here the pointer is browsing between tiles, and the watcher
        // reports the next one at once, with no dwell.
        DockHoverWatcher.shared.isShowingPreview = true
        place(panel, for: tile, size: size)

        // A row installed under a pointer already resting on it — the panel
        // re-forming after a close — highlights what is under the pointer at
        // once rather than waiting for a move. Only when the pointer is over a
        // thumbnail: elsewhere the kept selection stands.
        pointerIndex = hosting.pointerLocation.flatMap { layout.thumbnailIndex(at: $0) }
        if let pointerIndex { select(pointerIndex) }

        // Frames first, panel second: a preview that appears and then fills in a
        // frame at a time reads as slower than one that appears complete, even
        // when it is the same handful of milliseconds.
        engine.retain(.dock)
        engine.prime(target.windows.map { .window($0.id) })

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            // Long enough not to pop, short enough not to be waited for: it
            // sits on top of the dwell, and the two together are what the user
            // reads as how quickly the preview answers.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.08
                panel.animator().alphaValue = 1
            }
        }

        startPolling()
        // Only while there is a panel to steer. See `DockPreviewKeys`.
        keys.start()
    }

    private func makePanel() -> DockPreviewPanel {
        let panel = DockPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        // Above the Dock, which sits at level 20. Anything at or below it would
        // be drawn behind the very thing the preview is anchored to.
        panel.level = .popUpMenu
        // Transparent window with an opaque content view, rather than an opaque
        // window: it is what lets the corners be rounded and the shadow follow
        // the rounded shape instead of a hard rectangle.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The panel never becomes key and this app never activates, so AppKit
        // would otherwise not bother tracking the pointer inside it — which is
        // what SwiftUI's hover highlighting on each thumbnail is built on.
        panel.acceptsMouseMovedEvents = true
        // Follows the user to whatever Space they are on, and survives another
        // app going full screen — a Dock revealed over a full-screen window
        // still needs its previews.
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]

        // Layer-backed and masked, which a borderless window needs to have any
        // rounded shape at all: `DeckWindow` gets its corners from the `.titled`
        // style mask, and a panel with no title bar has nothing to get them from.
        //
        // The mask radius matches the material's own — see
        // `DeckBackgroundView.cornerRadius` — so it clips exactly where the glass
        // has already stopped drawing, rather than shaving off the lensed edge
        // that makes it read as glass.
        let background = DeckBackgroundView()
        background.wantsLayer = true
        background.layer?.cornerRadius = DeckBackgroundView.cornerRadius
        background.layer?.masksToBounds = true
        panel.contentView = background
        self.background = background

        return panel
    }

    private func install(_ hosting: NSView) {
        guard let background else { return }
        // One hosting view at a time: each show builds a fresh hierarchy for a
        // different set of windows, and leaving the previous one underneath
        // would keep its thumbnails subscribed to the feed.
        background.subviews.filter { $0 is NSHostingView<DockPreviewView> }
            .forEach { $0.removeFromSuperview() }

        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    /// Matches the deck's appearance preference, so glass and solid mode look
    /// like one app rather than two.
    ///
    /// The ground is painted on the content view's layer rather than set as the
    /// window's background colour, which is what the deck window does. A window
    /// background fills the window's own rectangle, corners included, and would
    /// draw square shoulders outside the rounded content this panel is clipped
    /// to.
    private func applyAppearance() {
        guard let background else { return }
        let prefs = Preferences.shared
        let appearance = RenderOptions.appearance
        background.apply(appearance, style: prefs.glassStyle, tint: prefs.glassTint)

        // In glass mode there is no ground to paint: the material is the ground,
        // and a colour behind it would be the thing it refracted.
        background.layer?.backgroundColor = appearance == .solid
            ? prefs.resolvedSolidBackground.cgColor
            : NSColor.clear.cgColor
    }

    // MARK: - Choosing a thumbnail

    /// How many thumbnails the row is showing. A target with no windows is
    /// showing a single remembered still, which is still something to choose.
    private var shownCount: Int {
        guard let shownTarget else { return 0 }
        if !shownTarget.windows.isEmpty { return shownTarget.windows.count }
        return shownTarget.still == nil ? 0 : 1
    }

    /// The pointer moving over the panel, or leaving it.
    ///
    /// Every position is resolved against the row's layout, so there are no
    /// enter-and-leave pairs to put in order: arriving on a thumbnail chooses
    /// it, and leaving one for nothing — a gap, the header, off the panel —
    /// clears the highlight only if it is still that thumbnail's. A pointer
    /// that was never on a thumbnail changes nothing, so the arrow keys can be
    /// used with the pointer parked anywhere on the panel.
    private func pointer(at point: CGPoint?) {
        let index = point.flatMap { shownLayout?.thumbnailIndex(at: $0) }
        guard index != pointerIndex else { return }
        let previous = pointerIndex
        pointerIndex = index
        if let index {
            select(index)
        } else if selection.index == previous {
            select(nil)
        }
    }

    /// Moves the highlight along the row. See `DockPreviewSelection.stepping`
    /// for where it goes and why it does not wrap.
    ///
    /// A key that lands on the end of the row is still consumed: it was aimed at
    /// this panel, and letting it fall through would scroll a document the user
    /// cannot currently see.
    private func step(_ delta: Int) -> Bool {
        guard let next = DockPreviewSelection.stepping(
            from: selection.index, by: delta, count: shownCount
        ) else { return false }
        select(next)
        return true
    }

    /// Moves the highlight, and nothing else.
    ///
    /// It used to also redistribute the capture budget, giving the chosen window
    /// every frame and dropping the rest to a fifth of the rate. The whole row is
    /// subscribed at the full rate now — see `show` — so choosing a thumbnail is
    /// purely a statement about what Return will act on.
    private func select(_ index: Int?) {
        guard selection.index != index else { return }
        selection.index = index
    }

    /// Pulls the highlight back into a row that has just got shorter.
    ///
    /// Held at the last thumbnail rather than dropped, for the same reason
    /// `DockPreviewSelection.stepping` holds at the ends: the row is entirely
    /// visible, and the nearest thumbnail to where the highlight was is a better
    /// answer than no highlight at all.
    private func clampSelection() {
        guard let index = selection.index else { return }
        selection.index = shownCount > 0 ? min(index, shownCount - 1) : nil
    }

    /// Drops a closed window from what the panel thinks it is showing, at once
    /// rather than in 0.35s when the rebuild arrives.
    ///
    /// The gap matters because the arrow keys and Return go on working during
    /// it, and they are bounded by this row: a highlight left pointing past the
    /// end of it would have Return act on a window that has just been closed.
    ///
    /// `shownLayout` is deliberately not rebuilt here. It describes the row the
    /// panel is *drawing*, which does not change until `show` runs again — that
    /// is the whole reason `DockCloseSelfTest` can aim at a real button with it —
    /// so re-fitting it to the shortened row would make it describe a panel that
    /// is not on screen yet.
    private func forget(_ window: WindowServerCapture.WindowRef) {
        shownTarget?.windows.removeAll { $0.id == window.id }
        clampSelection()
    }

    /// Acts on the highlighted thumbnail, exactly as clicking it would.
    private func activateSelection() -> Bool {
        guard let shownTarget, let index = selection.index else { return false }

        if shownTarget.windows.indices.contains(index) {
            // The key was aimed at this panel either way, so it is consumed
            // either way — but a window that could not be reached, and whose app
            // could not be asked for one either, leaves the preview up rather
            // than dismissing it over nothing having happened. Return does
            // exactly what a click does, fallback included. See
            // `DockWindows.activateOrOpen`.
            guard DockWindows.activateOrOpen(
                window: shownTarget.windows[index], of: shownTarget
            ) else { return true }
        } else if shownTarget.still != nil {
            DockWindows.open(shownTarget)
        } else {
            return false
        }
        hide()
        return true
    }

    /// Returns whether the key was used — which is what decides whether the
    /// application in front still gets it. See `DockPreviewKeys`.
    private func handle(_ key: DockPreviewKeys.Key) -> Bool {
        guard let panel, panel.isVisible else { return false }

        // Not merely "a panel is up". See `DockPreviewSelection.panelOwnsKeyboard`:
        // every key this answers is a key taken away from the application in
        // front, and a preview that appears from resting the pointer near the
        // Dock has been given no reason to think those keys were meant for it.
        guard DockPreviewSelection.panelOwnsKeyboard(
            panel: panel.frame, pointer: NSEvent.mouseLocation
        ) else { return false }

        switch key {
        case .previous: return step(-1)
        case .next:     return step(1)
        case .activate: return activateSelection()
        case .dismiss:
            hide()
            return true
        }
    }

    // MARK: - Placement

    /// Puts the panel beside the tile, on the side away from the screen edge the
    /// Dock is against, and clamped so it never runs off the display.
    ///
    /// Anchored to the tile rather than to the pointer. A panel that tracked the
    /// pointer would slide about under a hand that is only trying to reach it,
    /// and the thing being previewed is the tile.
    private func place(_ panel: NSPanel, for tile: DockProbe.Tile, size: NSSize) {
        let visible = screen(for: tile)?.visibleFrame ?? NSRect(origin: .zero, size: size)

        var origin: NSPoint
        switch DockProbe.edge() {
        case .bottom:
            origin = NSPoint(
                x: tile.frame.midX - size.width / 2,
                y: tile.frame.maxY + gap
            )
        case .left:
            origin = NSPoint(
                x: tile.frame.maxX + gap,
                y: tile.frame.midY - size.height / 2
            )
        case .right:
            origin = NSPoint(
                x: tile.frame.minX - gap - size.width,
                y: tile.frame.midY - size.height / 2
            )
        }

        // `max` inside `min`, so a panel wider or taller than the usable screen
        // is pinned to the near edge rather than pushed off the far one.
        origin.x = max(
            visible.minX + margin,
            min(origin.x, visible.maxX - size.width - margin)
        )
        origin.y = max(
            visible.minY + margin,
            min(origin.y, visible.maxY - size.height - margin)
        )

        let frame = NSRect(origin: origin, size: size)
        guard frame != shownFrame else { return }
        shownFrame = frame
        panel.setFrame(frame, display: true)
        // The shadow is derived from the rendered shape, so it has to be redone
        // whenever the shape moves or resizes.
        panel.invalidateShadow()
    }

    /// The display the tile is on, which is the one the panel has to fit.
    private func screen(for tile: DockProbe.Tile) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(tile.frame) } ?? NSScreen.main
    }

    /// How wide the row may be before it runs off that display. The placement
    /// code can only slide a panel that does not fit, so the row is fitted to the
    /// screen before there is a panel to place.
    private func availableWidth(for tile: DockProbe.Tile) -> CGFloat {
        (screen(for: tile)?.visibleFrame.width ?? 1280) - margin * 2
    }

    // MARK: - Dismissal

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { DockPreviewController.shared.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func poll() {
        guard let panel, panel.isVisible, let shownTile else {
            stopPolling()
            return
        }

        // The tile, the panel, and everything between them count as "still
        // here". The corridor matters: reaching a thumbnail means crossing the
        // gap the panel was deliberately placed above, and a preview that
        // vanished mid-reach would be unusable. Including neighbouring tiles in
        // that union is harmless, because moving onto one of those is reported
        // as a new hover and switches the preview rather than dismissing it.
        let hotZone = shownTile.frame.union(panel.frame).insetBy(dx: -6, dy: -6)

        if hotZone.contains(NSEvent.mouseLocation) {
            awaySince = nil
            return
        }

        guard let awaySince else {
            self.awaySince = Date()
            return
        }
        if Date().timeIntervalSince(awaySince) >= grace { hide() }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Re-forms the preview around whatever windows the tile has left.
    ///
    /// Delayed, because closing a window is asynchronous in the app that owns
    /// it: asking the window server a millisecond later would list the window
    /// that is on its way out and rebuild an identical panel.
    ///
    /// The window just closed is then dropped from the rebuild rather than
    /// trusted to have left the window server's list, and that is not belt and
    /// braces — it is the whole reason the close button appeared not to work.
    /// A closed window keeps its entry in that list for about 0.2s, measured,
    /// which is inside this delay often enough to matter; the rebuild would put
    /// its thumbnail straight back, and the thumbnail would then subscribe to
    /// the capture engine, which keeps the dead window's backing store alive and
    /// its entry in the list indefinitely. The cross closed the window and the
    /// panel then reassembled itself around the corpse, so nothing appeared to
    /// happen at all.
    ///
    /// A window still *on screen* is kept, because that is the case where the
    /// close genuinely did not happen: an app with unsaved changes answers the
    /// press with a save sheet and keeps its window.
    private func rebuildAfterClosing(_ closed: WindowServerCapture.WindowRef) {
        guard let tile = shownTile else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shownTile?.isSameTile(as: tile) == true else { return }
                guard var target = DockWindows.target(for: tile) else {
                    self.hide()
                    return
                }
                target.windows.removeAll { $0.id == closed.id && !$0.isOnScreen }
                guard !target.windows.isEmpty else {
                    self.hide()
                    return
                }
                // The same row, one shorter — so the highlight comes with it.
                self.show(target, for: tile, keepingSelection: true)
            }
        }
    }

    func hide() {
        stopPolling()
        // The tap goes with the panel. A keyboard tap outliving the thing it
        // steers would be this app quietly reading every keystroke on the
        // system between hovers.
        keys.stop()
        awaySince = nil
        shownTile = nil
        shownFrame = .zero
        shownTarget = nil
        shownLayout = nil
        selection.index = nil
        pointerIndex = nil
        DockHoverWatcher.shared.isShowingPreview = false

        let engine = LiveWindowPreview.shared
        engine.cancelPriming()
        engine.clearWindowDemands()
        engine.release(.dock)

        // The hierarchy goes with the panel rather than lingering off screen:
        // its thumbnails hold slots in the feed, and the next hover builds its
        // own for a different set of windows anyway.
        //
        // Above the visibility check rather than below it. A panel that was built
        // and then abandoned before it was ever ordered front is not visible, and
        // leaving its hosting view parented would keep a `Slot` — and, through
        // it, the window's backing store — alive until some later hover happened
        // to replace it. See `LiveWindowPreview.forgetWindow` for why a held
        // frame is not merely wasted memory.
        background?.subviews.filter { $0 is NSHostingView<DockPreviewView> }
            .forEach { $0.removeFromSuperview() }

        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }
}
