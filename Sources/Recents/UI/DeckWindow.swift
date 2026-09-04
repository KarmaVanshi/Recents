import AppKit
import SwiftUI

/// A normal application window that happens to be summoned by a hotkey.
///
/// It behaves like any other app window — titled, movable, resizable, remembers
/// its size, stays open while the user works alongside it — but its background is
/// glass rather than a solid fill: the window itself is transparent and an
/// `NSGlassEffectView` refracts whatever sits behind it.
///
/// Transparency has to be set on the window, not just painted in SwiftUI. AppKit
/// short-circuits drawing behind an opaque window, so `isOpaque` must be false
/// and `backgroundColor` clear before the material has anything to sample. The
/// `.titled` style mask stays because it is what clips the content to the
/// system's rounded-corner shape and draws the window shadow — without it the
/// glass would be a hard-edged rectangle.
///
/// Being a normal window also unlocks things a panel could not do: the system
/// `QLPreviewView` works properly inside it (it fought the old `.screenSaver`
/// panel for key status), and the window can be left open alongside other apps.
final class DeckWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = "Recent Items"
        // Content runs to the top edge under a transparent title bar: the deck
        // supplies its own header, so a second opaque bar would be redundant.
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true

        // Opacity and background colour are owned by `applyAppearance()`, which
        // runs before the window is first shown. The shadow is constant: it is
        // what separates the pane from whatever it floats over, in both modes.
        hasShadow = true

        minSize = NSSize(width: 720, height: 520)
        isReleasedWhenClosed = false
        // Restores position and size across launches, like any other app window.
        setFrameAutosaveName("RecentsDeckWindow")

        collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

extension Notification.Name {
    /// Posted whenever the deck leaves the screen, by any route — the hotkey,
    /// ⌘W, the red button, or opening an item. The window is only ordered out,
    /// never torn down, so this is what tells the view to drop the state that
    /// should not survive a dismissal.
    static let recentsDeckDidHide = Notification.Name("recents.deckDidHide")
}

/// Owns the window's lifecycle: when it appears, and what happens to focus.
@MainActor
final class DeckWindowController: NSObject, NSWindowDelegate {

    private var window: DeckWindow?
    private var background: DeckBackgroundView?
    private var appearanceObserver: NSObjectProtocol?
    private var livePreviewObserver: NSObjectProtocol?
    private let store: RecentsStore

    /// The app that was frontmost when we were summoned. Captured *before*
    /// activation, because once we activate this information is gone — and
    /// without it, closing the deck drops the user on the Finder instead of back
    /// where they were working.
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { window?.isVisible ?? false }

    init(store: RecentsStore) {
        self.store = store
        super.init()

        // The appearance switch has to reach the window, which SwiftUI's
        // observation cannot do — see `Preferences.deckAppearance`.
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .recentsAppearanceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }

        // Toggling live previews takes effect immediately rather than on the
        // next summon, so the setting can be judged against a deck the user is
        // already looking at.
        livePreviewObserver = NotificationCenter.default.addObserver(
            forName: .recentsLivePreviewSettingChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                LiveWindowPreview.shared.reload()
                // `reload` preserves whatever the engine was already doing; if it
                // was off because the setting was off, the deck being open is
                // what should now start it.
                if self?.isVisible == true { LiveWindowPreview.shared.retain(.deck) }
            }
        }
    }

    deinit {
        for observer in [appearanceObserver, livePreviewObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Window delegate

    /// The red close button orders the window out without routing through
    /// `hide()`, so without this the live-preview engine would keep capturing
    /// for a deck that is no longer on screen.
    func windowWillClose(_ notification: Notification) {
        LiveWindowPreview.shared.release(.deck)
        NotificationCenter.default.post(name: .recentsDeckDidHide, object: nil)
        // The same focus restoration ⎋ and ⌘W get. Closing the deck three
        // different ways should land the user in the same place — and leaving
        // `previousApp` set here meant the next summon inherited a stale one and
        // returned the user to whatever had been in front two dismissals ago.
        restorePreviousApp()
    }

    /// The hotkey means "bring me the deck", not "toggle a boolean".
    ///
    /// A visible-but-buried window is the common case now that this is an
    /// ordinary window the user can click away from: treating that as "already
    /// open" made the shortcut dismiss a deck the user could see but not reach.
    /// It only hides when it is genuinely the thing in front of you.
    func toggle() {
        if isVisible, isFrontmost {
            hide()
        } else {
            show()
        }
    }

    /// True when the deck is not just on screen but actually the focused window.
    private var isFrontmost: Bool {
        guard let window, window.isVisible else { return false }
        return NSApp.isActive && window.isKeyWindow
    }

    /// Bring the deck to the front, whatever state it is in.
    ///
    /// There used to be a fast path here for a deck that was already on screen,
    /// and it was the bug behind "clicking the menu bar icon does nothing":
    /// `makeKeyAndOrderFront` alone orders a window to the front *of its own
    /// application*, and this app is `.accessory`, so clicking the status item
    /// does not activate it. With another app frontmost, AppKit defers the
    /// ordering until activation that never came — the deck stayed exactly where
    /// it was, behind whatever the user was working in, and the shortcut looked
    /// broken. `NSApp.activate` is the half that was missing, and there is no
    /// longer a path through this function that skips it.
    ///
    /// Everything else the fast path skipped was worth doing too: a deck that
    /// has been sitting buried for ten minutes is the one that most needs its
    /// items and its screenshots refreshed before the user looks at it again.
    func show() {
        let wasVisible = isVisible

        // Read before activating: once we are frontmost this is gone, and
        // without it ⎋ drops the user on the Finder instead of back where they
        // were. Re-read on every summon, not just the first — a buried deck can
        // be left on screen for hours while the user works elsewhere, and the
        // app to return to is the one they were in a moment ago, not the one
        // they were in when the deck first appeared. Guarded, because summoning
        // an already-frontmost deck would otherwise record *us* as the app to
        // return to.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }

        let window = self.window ?? makeWindow()
        self.window = window

        store.refresh()

        // The user is about to look at these cards, so this is the one moment
        // where spending a screenshot per visible app is obviously worth it —
        // and it is what keeps a card current for an app that has been sitting
        // idle since the last capture.
        AppWindowCapture.shared.refreshVisible()

        // Centre on the display holding the pointer, so on a multi-display setup
        // the deck appears where the user is actually looking — but only when it
        // is not already there. The window is movable by its background and its
        // frame is autosaved; recentring unconditionally threw away the position
        // the user had chosen every single time they summoned it. The same test
        // is right for a deck that was already open: it only moves when the deck
        // is on a display the user is not looking at, which is the one case
        // where leaving it put would look like nothing happened.
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main

        if let screen, !screen.visibleFrame.contains(window.frame.center) {
            let frame = window.frame
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2
            ))
        }

        // Both halves, in this order, every time. See the note above: the
        // activation is what lets the ordering actually happen.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // A window ordered front while another app was active can still lose the
        // race to that app's own ordering. This is the belt to the activation's
        // braces, and it is a no-op when the window is already in front.
        if wasVisible { window.orderFrontRegardless() }

        // Live previews exist only for a deck someone is looking at.
        LiveWindowPreview.shared.retain(.deck)
    }

    private func makeWindow() -> DeckWindow {
        let window = DeckWindow()
        window.delegate = self

        // The background is the content view and the SwiftUI hierarchy is its
        // child, rather than the material view bridged into SwiftUI.
        // Putting it at the root means AppKit masks it to the window's rounded
        // corners for us, and there is no layer between it and the window for
        // SwiftUI to paint an opaque background into.
        let background = DeckBackgroundView()

        let hosting = NSHostingView(rootView: DeckView(store: store, controller: self))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)

        // Constraints rather than autoresizing: assigning `contentView` resizes
        // the background to the window's content rect, and a frame set before
        // that would be stretched by the difference instead of matching it.
        window.contentView = background
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        self.window = window
        self.background = background
        applyAppearance()
        return window
    }

    /// Reconfigures the window for the current appearance preference.
    ///
    /// Both halves matter. AppKit short-circuits drawing behind an opaque window,
    /// so glass needs `isOpaque == false` and a clear background before the blur
    /// has anything to sample; solid wants the opposite, because leaving the
    /// window transparent over an opaque fill pays the compositing cost for
    /// nothing.
    ///
    /// The explicit `appearance` in solid mode is what keeps text readable over a
    /// custom colour: `Color.primary` resolves against the window's appearance,
    /// so a dark ground chosen while macOS is in light mode would otherwise draw
    /// black captions on it.
    func applyAppearance() {
        guard let window, let background else { return }
        let prefs = Preferences.shared

        background.apply(
            prefs.deckAppearance, style: prefs.glassStyle, tint: prefs.glassTint
        )

        switch prefs.deckAppearance {
        case .liquidGlass:
            window.isOpaque = false
            window.backgroundColor = .clear
            // nil: follow the system, which is what the glass is sampling anyway.
            window.appearance = nil

        case .solid:
            let ground = prefs.resolvedSolidBackground
            window.isOpaque = true
            window.backgroundColor = ground
            window.appearance = prefs.usesSystemSolidBackground
                ? nil
                : NSAppearance(named: ground.deckLuminance < 0.5 ? .darkAqua : .aqua)
        }

        window.invalidateShadow()
        window.contentView?.needsDisplay = true
    }

    func hide(restoringFocus: Bool = true) {
        guard isVisible else { return }
        window?.orderOut(nil)
        LiveWindowPreview.shared.release(.deck)
        // `orderOut` fires no `windowWillClose` and no SwiftUI `onDisappear` —
        // the view hierarchy is still very much alive, just not on screen — so
        // this is the only signal the deck's transient state gets that it should
        // reset itself. Without it a peek, or a filter, outlives the dismissal
        // and is waiting there on the next summon.
        NotificationCenter.default.post(name: .recentsDeckDidHide, object: nil)

        if restoringFocus {
            restorePreviousApp()
        } else {
            previousApp = nil
        }
    }

    /// Puts focus back where the summon took it from, and forgets it either way
    /// — a `previousApp` left behind is one the *next* dismissal would wrongly
    /// return to.
    private func restorePreviousApp() {
        if let previousApp,
           previousApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    /// Open an item, then get out of the way. Closes without restoring the
    /// previous app — whatever we just opened is about to come forward, and
    /// reactivating the old app first causes a visible flicker.
    func open(_ item: RecentItem) {
        hide(restoringFocus: false)
        store.open(item)
    }

    /// Opens an item with a specific application rather than its default
    /// handler — what an application card's own recents should do.
    func open(_ item: RecentItem, using application: URL) {
        hide(restoringFocus: false)
        store.openWith(item, application: application)
    }
}
