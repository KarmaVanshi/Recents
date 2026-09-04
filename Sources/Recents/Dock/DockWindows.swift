import AppKit
import ApplicationServices

/// What a Dock tile actually stands for, and how to act on it.
///
/// A tile is a picture; the thing a preview has to show is the set of real
/// windows behind it. Answering that is the whole of `target(for:)`, and the
/// awkwardness is that the Dock's two previewable tile kinds identify their
/// windows in completely different ways: an application tile names a bundle and
/// implies every window that bundle owns, while a minimized-window tile names
/// one window by its title and says nothing at all about who owns it.
///
/// A running app with nothing open is still worth previewing: the deck has been
/// keeping the last window it ever saw of that app on disk since long before
/// this feature existed, and that remembered still is a far better answer to
/// "what is behind this icon" than a blank panel. So a target carries either
/// windows or a still, and the panel shows whichever it has.
///
/// An app that is *not running* is not previewable at all, and that is a rule
/// rather than a shortcoming. A tile with no dot under it owns no window
/// anywhere — not minimized, not hidden, not on another Space — so anything
/// shown for it could only be a photograph of something that is no longer
/// there, hung over the Dock as though it were the present. `target(for:)`
/// answers nil for those, and the panel never opens.
@MainActor
enum DockWindows {

    /// A resolved tile: an app, and what a preview should show for it.
    struct Target {
        /// The application's name, for captioning a preview that has no window
        /// title of its own to show.
        var name: String
        var bundleID: String
        /// The application bundle, for its icon and for launching it.
        var applicationURL: URL?
        /// Live windows, front to back, on-screen ones first. Empty when the app
        /// has none right now. Capped at `maximumWindows`.
        var windows: [WindowServerCapture.WindowRef]
        /// How many previewable windows the app has, before the cap.
        ///
        /// Carried so the panel can say that it is showing six of eleven rather
        /// than quietly presenting six as the whole answer. A browser left open
        /// for a week owns thirty windows, and a preview that silently drops
        /// twenty-four of them is telling the user something untrue about what
        /// is behind that icon.
        ///
        /// Previewable, not owned: this counts what `candidateWindows()` hands
        /// over, which already drops anything under 200×150, off layer zero, or
        /// offscreen with no title. So an app with a dozen inspector palettes
        /// does not claim a dozen windows the panel would have nothing to show
        /// for — which is the honest number here, since the sentence this feeds
        /// is about what the preview is leaving out.
        var totalWindows: Int = 0
        /// The last window Recents ever saw of this app. Only consulted when
        /// `windows` is empty — a remembered frame must never stand in for a
        /// window that could have been read live.
        var still: AppWindowCapture.Capture?
        /// The file that still was showing, when it can be established.
        ///
        /// What a click on a still opens. The picture is of one document, so
        /// opening the app to a new empty window instead is not what it
        /// promised — and for an app like Word, whose tile is hovered precisely
        /// to check *which* document was left in it, it is the whole answer.
        var document: URL?
    }

    /// Ceiling on thumbnails in one preview.
    ///
    /// A browser left open for a week can own thirty windows. Past a handful the
    /// panel is wider than the screen and every thumbnail is too small to read,
    /// and the refresh budget is being spread across windows nobody is looking
    /// at. Six is about as many as fit comfortably above a Dock tile.
    private static let maximumWindows = 6

    // MARK: - Resolution

    static func target(for tile: DockProbe.Tile) -> Target? {
        switch tile.kind {
        case .application: return applicationTarget(for: tile)
        case .minimizedWindow: return minimizedWindowTarget(for: tile)
        }
    }

    private static func applicationTarget(for tile: DockProbe.Tile) -> Target? {
        let app = runningApplication(for: tile)
        let url = app?.bundleURL ?? tile.url

        // The dot decides. See the note at the top of this file: a tile for an
        // app that is not running has nothing behind it to preview, and the
        // Dock's own answer about its own indicator is preferred to ours. The
        // workspace stands in only when the Dock declines to answer.
        guard tile.isRunning ?? (app != nil) else { return nil }

        // Still read from the bundle when it comes to it: an app running under
        // a name `runningApplication(for:)` did not match has no
        // `NSRunningApplication` here, and its remembered still is filed under
        // the identifier the tile's own bundle carries.
        guard let bundleID = app?.bundleIdentifier
                ?? url.flatMap({ Bundle(url: $0)?.bundleIdentifier })
        else { return nil }

        // A preview of ourselves is never useful, and the capture policy that
        // keeps password managers and the authentication agent out of the deck's
        // disk cache applies here for exactly the same reason — this puts their
        // window on screen next to the Dock, in front of whoever is standing
        // behind the user.
        guard bundleID != Bundle.main.bundleIdentifier,
              AppWindowCapture.isCaptureAllowed(bundleID: bundleID)
        else { return nil }

        let windows = app.map { orderedWindows(forPID: $0.processIdentifier) } ?? []
        let still = windows.isEmpty
            ? AppWindowCapture.shared.capture(forBundleID: bundleID)
            : nil

        // Running, but every window closed and none ever seen: a tile there is
        // genuinely nothing to say about.
        guard !windows.isEmpty || still != nil else { return nil }

        return Target(
            name: app?.localizedName ?? tile.title,
            bundleID: bundleID,
            applicationURL: url,
            windows: Array(windows.prefix(maximumWindows)),
            totalWindows: windows.count,
            still: still,
            document: still.flatMap { rememberedDocument(of: $0, bundleID: bundleID) }
        )
    }

    /// A minimized-window tile carries only the window's title, so the window is
    /// found by matching that title against the offscreen windows on the system.
    ///
    /// Ambiguity is possible in principle — two apps with an identically titled
    /// minimized window — and is resolved by taking the first, which is the
    /// front-most in the window server's own ordering. Getting that wrong shows
    /// the user a preview of a window with the same name as the one they are
    /// pointing at, which is a far better failure than showing nothing.
    private static func minimizedWindowTarget(for tile: DockProbe.Tile) -> Target? {
        guard !tile.title.isEmpty else { return nil }

        let all = WindowServerCapture.candidateWindows()
        guard let window = all.first(where: { !$0.isOnScreen && $0.title == tile.title })
                ?? all.first(where: { $0.title == tile.title })
        else { return nil }

        let app = NSRunningApplication(processIdentifier: window.pid)
        guard let bundleID = app?.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              AppWindowCapture.isCaptureAllowed(bundleID: bundleID)
        else { return nil }

        return Target(
            name: app?.localizedName ?? tile.title,
            bundleID: bundleID,
            applicationURL: app?.bundleURL,
            windows: [window],
            totalWindows: 1,
            still: nil,
            document: nil
        )
    }

    /// Every previewable window a process owns, on screen first.
    ///
    /// `candidateWindows()` is already in the order the window server keeps —
    /// front to back — and that order is worth preserving inside each group,
    /// because it is the order the user last used those windows in. What it is
    /// not is a reason to interleave: a window the user can see right now is a
    /// more useful first thumbnail than one that has been minimized for an hour.
    private static func orderedWindows(forPID pid: pid_t) -> [WindowServerCapture.WindowRef] {
        let mine = WindowServerCapture.candidateWindows().filter { $0.pid == pid }
        return mine.filter(\.isOnScreen) + mine.filter { !$0.isOnScreen }
    }

    /// Finds the running application a Dock tile points at, or nil when it is not
    /// running — which is not a failure, only the case the remembered still
    /// exists for.
    ///
    /// By bundle identifier read from the tile's own URL first, which is exact.
    /// The name comparison behind it covers tiles whose URL is missing or points
    /// at a bundle that has since moved.
    private static func runningApplication(for tile: DockProbe.Tile) -> NSRunningApplication? {
        if let url = tile.url, let bundleID = Bundle(url: url)?.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
           ).first(where: { !$0.isTerminated }) {
            return app
        }

        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.localizedName == tile.title
        }
    }

    // MARK: - Acting on a window

    /// Brings one window forward: un-minimizes it if it needs it, raises it
    /// within its app, and activates that app.
    ///
    /// All three steps, in that order, because each one alone leaves the user
    /// somewhere short of what they asked for. Un-minimizing a window without
    /// raising it restores it behind whatever is in front; raising without
    /// activating orders it within an application that is still in the
    /// background, which on screen looks like nothing happened at all.
    ///
    /// The app is activated only once the window has actually been reached. It
    /// used to be activated unconditionally, from a `defer`, and that turned an
    /// unreachable window into something worse than a no-op: an app whose window
    /// Accessibility cannot see — Notes, minimized, measured on macOS 26 — came
    /// to the front showing some *other* window, while the one in the picture
    /// stayed in the Dock. The user asked for one window and got a different
    /// one, with nothing to say so.
    @discardableResult
    static func activate(window: WindowServerCapture.WindowRef) -> ActionOutcome {
        guard let element = element(for: window) else { return .noElement }
        AXUIElementSetAttributeValue(
            element, kAXMinimizedAttribute as CFString, kCFBooleanFalse
        )
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        return .done
    }

    /// Closes a window from its thumbnail.
    ///
    /// By pressing the window's own close button rather than by sending ⌘W to
    /// the app. The keystroke goes to whatever is frontmost and would close the
    /// wrong document entirely; the button belongs to this window and to no
    /// other, and it also lets the app run whatever it normally runs on close —
    /// a "save changes?" sheet included.
    @discardableResult
    static func close(window: WindowServerCapture.WindowRef) -> ActionOutcome {
        guard let element = element(for: window) else { return .noElement }
        return press(kAXCloseButtonAttribute, of: element)
    }

    /// What happened when a window was asked to do something from its thumbnail.
    ///
    /// Reported rather than discarded because every failure along these paths is
    /// silent from the outside: no element, no button, a disabled button and a
    /// refused press all look identical to a user whose window did not move.
    ///
    /// One enum for all three actions rather than one per action. They fail in
    /// exactly the same ways because they are the same two mechanisms — resolve
    /// the window through Accessibility, press one of its title-bar buttons —
    /// and it was having this only on the close path that let `activate` and
    /// `zoom` go on swallowing the identical failure.
    enum ActionOutcome: Equatable {
        case done
        case noElement
        case noButton
        case buttonDisabled
        case pressFailed(AXError)

        var isSuccess: Bool { self == .done }

        var describe: String {
            switch self {
            case .done: return "done"
            case .noElement: return "no accessibility element for this window"
            case .noButton: return "window has no such title-bar button"
            case .buttonDisabled: return "title-bar button is disabled"
            case .pressFailed(let error): return "press refused (AXError \(error.rawValue))"
            }
        }
    }

    /// Presses one of a window's title-bar buttons and says what happened.
    private static func press(
        _ attribute: String, of element: AXUIElement
    ) -> ActionOutcome {
        guard let button = button(attribute, of: element) else { return .noButton }
        guard isEnabled(button) else { return .buttonDisabled }
        let error = AXUIElementPerformAction(button, kAXPressAction as CFString)
        return error == .success ? .done : .pressFailed(error)
    }

    /// Whether an accessibility element reports itself as enabled. A minimized
    /// window's title-bar buttons are the case this exists for.
    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXEnabledAttribute as CFString, &value
        ) == .success else { return true }
        return (value as? Bool) ?? true
    }

    /// Read-only account of whether this window could be closed from a
    /// thumbnail, for the self test. Touches nothing.
    static func closeReadiness(
        of window: WindowServerCapture.WindowRef
    ) -> String {
        let (element, route) = resolve(window)
        guard let element else { return "no AX element" }

        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        let found = "via \(route.rawValue), id "
            + "\(identifier(of: element).map(String.init) ?? "unresolved")"
            + ", \"\((title as? String) ?? "—")\""

        guard let button = button(kAXCloseButtonAttribute, of: element) else {
            return "\(found) — no AXCloseButton"
        }
        return "\(found) — button "
            + "\(isEnabled(button) ? "enabled" : "DISABLED")"
    }

    /// Zooms a window from its thumbnail — the green button, not full screen.
    ///
    /// Un-minimized first, because a window that is not on screen has no zoom
    /// button to press, and "maximise" on a minimized window can only sensibly
    /// mean "bring it back, at full size". Raised and activated afterwards for
    /// the same reason `activate` does: a window resized in the background is a
    /// change the user cannot see.
    ///
    /// The press is then retried while the window is still on its way back, and
    /// that is the whole of what made this button a lie for minimized windows. A
    /// minimized window reports its title-bar buttons as disabled — the very
    /// condition `.buttonDisabled` exists to name on the close path — and
    /// un-minimizing is the application's own animation rather than something
    /// that has finished when the setter returns. A press issued in the same
    /// breath as the restore therefore landed on a button that would not answer,
    /// the error was discarded, and the window came back at exactly the size it
    /// left at: a maximise button that reliably restored and never maximised.
    ///
    /// Retried rather than waited for, because this runs on the main thread the
    /// pointer is tracked on and a blocking wait would freeze the panel being
    /// clicked. It gives up after `zoomRetries`, rather than pressing a button on
    /// a window the user has since done something else with.
    ///
    /// Returns what could be settled at once — a window that cannot be reached at
    /// all, which is what lets the thumbnail say so before the panel goes — while
    /// the final outcome, up to half a second away for a restored window, arrives
    /// through `report`.
    @discardableResult
    static func zoom(
        window: WindowServerCapture.WindowRef,
        then report: @escaping (ActionOutcome) -> Void = { _ in }
    ) -> ActionOutcome {
        guard let element = element(for: window) else {
            report(.noElement)
            return .noElement
        }

        let wasMinimized = !window.isOnScreen
        AXUIElementSetAttributeValue(
            element, kAXMinimizedAttribute as CFString, kCFBooleanFalse
        )
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: window.pid)?.activate()

        let outcome = press(kAXZoomButtonAttribute, of: element)
        guard wasMinimized, outcome == .buttonDisabled else {
            report(outcome)
            return outcome
        }
        pressZoom(of: element, attemptsLeft: zoomRetries, then: report)
        // The restore is done and visible; the maximise is still in flight.
        return .done
    }

    /// How many times a zoom is re-attempted while a window comes back from the
    /// Dock, and how far apart. Half a second in all, which covers the restore
    /// with room to spare on every app measured.
    private static let zoomRetries = 8
    private static let zoomRetryInterval: TimeInterval = 0.0625

    private static func pressZoom(
        of element: AXUIElement, attemptsLeft: Int,
        then report: @escaping (ActionOutcome) -> Void
    ) {
        guard attemptsLeft > 0 else { report(.buttonDisabled); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + zoomRetryInterval) {
            MainActor.assumeIsolated {
                let outcome = press(kAXZoomButtonAttribute, of: element)
                guard outcome == .buttonDisabled else { report(outcome); return }
                pressZoom(of: element, attemptsLeft: attemptsLeft - 1, then: report)
            }
        }
    }

    /// What clicking a remembered still does: reopen the document the still is
    /// a picture of, and failing that, open the app.
    ///
    /// There is no window to raise — that is what makes it a still — so the
    /// click cannot lead back to the thing in the picture. Opening the document
    /// it shows is as close as it gets, and it is exactly what someone hovering
    /// Word's tile to see which paper they left in it is asking for. With no
    /// document to name, the app is opened and lands in a new empty window,
    /// which the thumbnail says out loud before it is clicked.
    static func open(_ target: Target) {
        guard let application = target.applicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        if let document = target.document {
            NSWorkspace.shared.open(
                [document], withApplicationAt: application, configuration: configuration
            )
        } else {
            NSWorkspace.shared.openApplication(at: application, configuration: configuration)
        }
    }

    // MARK: - Which document a preview is of

    /// The document a remembered still was showing, or nil when nothing
    /// establishes it.
    ///
    /// Two routes, and the order between them is the point. The recorded one is
    /// the app's own answer, read from `AXDocument` while the window still
    /// existed and kept with the frame; the title route is a reconstruction,
    /// used only when there is no recorded answer — a still can be older than
    /// this feature, and the on-disk cache is months of windows captured before
    /// anything was recording documents.
    ///
    /// The reconstruction is an exact name match against the app's *own* recent
    /// documents, and deliberately nothing looser. A near match would open the
    /// wrong file, which is worse than opening none: the point of the whole
    /// path is that the panel promised a particular document.
    private static func rememberedDocument(
        of capture: AppWindowCapture.Capture, bundleID: String
    ) -> URL? {
        if let recorded = capture.documentURL, exists(recorded) { return recorded }

        guard let title = capture.windowTitle?.lowercased(), !title.isEmpty else { return nil }
        return recentDocuments(ofApp: bundleID).first { url in
            guard url.lastPathComponent.lowercased() == title
                    || url.deletingPathExtension().lastPathComponent.lowercased() == title
            else { return false }
            return exists(url)
        }
    }

    /// One app's own recent documents, from whichever store it keeps them in.
    ///
    /// The same two readers the deck builds its per-app sub-decks from, so the
    /// two surfaces agree about which file a name refers to. Office is asked
    /// first because it writes an *empty* shared list and keeps its real one
    /// privately — and Word is the app this path is most often asked about.
    private static func recentDocuments(ofApp bundleID: String) -> [URL] {
        if case .ok(let entries) = OfficeRecentsReader.read(bundleID: bundleID),
           !entries.isEmpty {
            return entries.map(\.url)
        }
        if case .ok(let urls) = SharedFileListReader.readAppDocuments(bundleID: bundleID) {
            return urls
        }
        return []
    }

    /// A document that has been moved or deleted since it was last seen would
    /// turn a click into an error sheet from the app, which is worse than the
    /// plain "opens in a new window" the panel falls back to saying.
    private static func exists(_ url: URL) -> Bool {
        url.isFileURL && FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Accessibility plumbing

    /// The file a window is showing, as the application itself reports it.
    ///
    /// `AXDocument` is the window's own claim about what it has open — the same
    /// thing the proxy icon in its title bar stands for — so it is exact where a
    /// window title is a guess. Read while the window is still there and kept
    /// with the captured frame, because by the time anybody asks which document
    /// a still is of, the window is gone.
    static func document(of window: WindowServerCapture.WindowRef) -> URL? {
        guard let element = element(for: window),
              let value: String = attribute(kAXDocumentAttribute, of: element),
              !value.isEmpty
        else { return nil }
        // Documented as a URL string, and returned as one by every app measured
        // — but a bare path is cheap to tolerate and impossible to recover from
        // if it is not.
        if value.hasPrefix("file:"), let url = URL(string: value) { return url }
        return URL(fileURLWithPath: value)
    }

    private static func attribute<T>(_ name: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, name as CFString, &value
        ) == .success else { return nil }
        return value as? T
    }

    /// One of a window's title-bar buttons, as an element that can be pressed.
    private static func button(
        _ attribute: String, of window: AXUIElement
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, attribute as CFString, &value
        ) == .success, let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    /// The accessibility element for a window the window server told us about.
    ///
    /// Three routes, because `AXWindows` alone does not answer for every app.
    /// Measured on macOS 26: Notes, Visual Studio Code and a freshly launched
    /// TextEdit all returned an *empty* `AXWindows` array — success, no error,
    /// no windows — while plainly owning a window the window server had just
    /// handed us pixels for. `AXChildren` and `AXMainWindow`/`AXFocusedWindow`
    /// each reach windows the others miss, and none of them is reliable on its
    /// own, so all three are tried.
    ///
    /// The single-window attributes are the delicate ones: they name whichever
    /// window the app considers frontmost, which is not necessarily the one
    /// being asked about. They are therefore accepted only when
    /// `_AXUIElementGetWindow` confirms the identifier matches — never on a
    /// title, and never as a last-ditch guess. Acting on the wrong window is
    /// worse than not acting: closing one is not undoable.
    private static func element(
        for window: WindowServerCapture.WindowRef
    ) -> AXUIElement? {
        resolve(window).element
    }

    /// Which of the three routes answered, alongside the element itself. The
    /// route is reported because the lookup is layered over app behaviour that
    /// is not documented and does change: knowing that a window was reached
    /// through `AXMainWindow` rather than `AXWindows` is the difference between
    /// a diagnosis and a guess.
    enum Route: String {
        case windows = "AXWindows"
        case children = "AXChildren"
        case mainWindow = "AXMainWindow"
        case focusedWindow = "AXFocusedWindow"
        case none = "nothing"
    }

    static func resolve(
        _ window: WindowServerCapture.WindowRef
    ) -> (element: AXUIElement?, route: Route) {
        guard AXIsProcessTrusted() else { return (nil, .none) }

        let application = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(application, 0.5)

        if let found = match(window, among: elements(kAXWindowsAttribute, of: application)) {
            return (found, .windows)
        }

        // The app's own children, filtered to windows. An app that does not
        // populate `AXWindows` may still expose the window here.
        let children = elements(kAXChildrenAttribute, of: application)
            .filter { role(of: $0) == kAXWindowRole }
        if let found = match(window, among: children) {
            return (found, .children)
        }

        for (attribute, route) in [
            (kAXMainWindowAttribute, Route.mainWindow),
            (kAXFocusedWindowAttribute, Route.focusedWindow),
        ] {
            guard let candidate = button(attribute, of: application),
                  identifier(of: candidate) == window.id
            else { continue }
            return (candidate, route)
        }

        return (nil, .none)
    }

    private static func elements(
        _ attribute: String, of element: AXUIElement
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &value
        ) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &value
        ) == .success else { return nil }
        return value as? String
    }

    /// The window-server identifier of an accessibility element, when the join
    /// between the two worlds is available. See `match`.
    private static func identifier(of element: AXUIElement) -> CGWindowID? {
        guard let getWindowID else { return nil }
        var identifier: CGWindowID = 0
        guard getWindowID(element, &identifier) == .success else { return nil }
        return identifier
    }

    /// Pairs a window-server window with its accessibility element.
    ///
    /// Accessibility and the window server describe the same windows through
    /// entirely separate handles, and nothing public joins them.
    /// `_AXUIElementGetWindow` does — it is how every window manager on macOS
    /// does this — so it is resolved at runtime and the join falls back to
    /// matching titles when it is not there. The fallback is genuinely worse:
    /// two untitled windows, or two documents with the same name, are
    /// indistinguishable by title. It is only ever reached on a system where the
    /// symbol has been removed, and the cost of being wrong is acting on the
    /// user's other window of the same name.
    private static func match(
        _ window: WindowServerCapture.WindowRef, among elements: [AXUIElement]
    ) -> AXUIElement? {
        for element in elements where identifier(of: element) == window.id {
            return element
        }

        guard let title = window.title, !title.isEmpty else { return nil }
        return elements.first { element in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, kAXTitleAttribute as CFString, &value
            ) == .success else { return false }
            return (value as? String) == title
        }
    }

    private typealias GetWindowFn = @convention(c) (
        AXUIElement, UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static let getWindowID: GetWindowFn? = {
        // Already linked into this process as part of HIServices, so there is no
        // bundle to open — only a symbol to look up.
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow"
        ) else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFn.self)
    }()
}
