import AppKit
import ApplicationServices
import CryptoKit
@preconcurrency import ScreenCaptureKit

/// Captures each application's last visible window and keeps it as that app's
/// card thumbnail.
///
/// This is what makes an app card show *your* work rather than a generic icon —
/// the brief calls for "the last window" of each recently used app.
///
/// The governing constraint used to be that macOS does not hand out the pixels of
/// a window that is not on screen. That is true of ScreenCaptureKit — a
/// `SCScreenshotManager` capture of an offscreen window throws, and an `SCStream`
/// on one delivers no frames ever — but it is not true of the OS.
/// `WindowServerCapture` reads a minimized window's live backing store directly,
/// so this class no longer has to treat a minimized app as unphotographable.
///
/// What remains is a two-tier arrangement:
///
///   • Whenever possible a capture is taken *now*, whatever state the window is
///     in. The window-server path handles minimized, hidden and buried windows;
///     ScreenCaptureKit is the fallback when that path is unavailable.
///   • Every capture is still written to disk with its metadata, and nothing is
///     ever evicted because an app was minimized, hidden or quit — a quit app has
///     no window to read, so the last frame we saw is genuinely all there is. A
///     card falls back to an icon only when we have never seen a window from that
///     app at all.
///
/// Captures are also taken at the moments a window's contents are about to stop
/// changing — app deactivation, app hide — and on a bounded periodic refresh of
/// whatever is frontmost. Restoration and window creation are observed through
/// Accessibility, so a deminiaturized window is re-read as soon as it is back,
/// and a window that did not exist when its app was activated is read as soon as
/// it does.
///
/// Live, moving previews are a separate concern; see `LiveWindowPreview`, which
/// drives the same window-server path at video rates while the deck is open.
///
/// Requires Screen Recording permission; Accessibility is optional and only
/// sharpens the restore case. Without either, everything degrades to app icons
/// and nothing breaks.
@MainActor
final class AppWindowCapture {

    static let shared = AppWindowCapture()

    /// One app's last known window, plus enough context to say how old it is and
    /// what it was.
    struct Capture {
        var image: NSImage
        var capturedAt: Date
        var windowTitle: String?
        /// The source window's size in points, as it was on screen.
        var sourceSize: CGSize
        /// The captured bitmap's size in pixels.
        var pixelSize: CGSize
        /// The file the window had open, when the app said which.
        ///
        /// Recorded here because it can only be read while the window exists and
        /// is only ever wanted once it is gone: it is what lets a click on a
        /// remembered still reopen the document in the picture instead of an
        /// empty new window.
        var documentURL: URL?
    }

    /// How an app stands right now, which decides whether its capture is live or
    /// a remembered one.
    enum Presence {
        /// Running with a window on screen: the capture is current.
        case live
        /// Running, but nothing on screen — minimized, hidden, or all windows
        /// closed. The window server can still be asked for a minimized window's
        /// pixels, so this no longer implies a stale frame; it only says the user
        /// cannot see the window anywhere else.
        case noVisibleWindow
        /// Not running. The last frame we ever saw stands, across relaunches.
        case notRunning
    }

    /// bundle identifier → last known window.
    private(set) var captures: [String: Capture] = [:]

    /// Bumped on every successful capture so SwiftUI views re-read `captures`.
    private(set) var generation = 0

    var onUpdate: (() -> Void)?

    private let diskDirectory: URL
    private var observers: [NSObjectProtocol] = []
    /// Kept apart from `observers`: this one is on the default centre, and
    /// `stop()` has to unregister it there rather than on the workspace centre.
    private var activationObserver: NSObjectProtocol?
    private var inFlight: Set<String> = []

    /// Bumped every time the cache is emptied.
    ///
    /// *Clear Captured Window Images* has to mean it, and ordering the deletion
    /// behind the writes already queued is only half of that. A capture is
    /// asked for and arrives some time later — up to the window-server deadline,
    /// longer through ScreenCaptureKit — so one that was in flight when the user
    /// pressed Clear would otherwise be written into the cache a moment after it
    /// was emptied, restoring a screenshot of exactly what they asked to be
    /// forgotten. `capturedAt` cannot decide this, because it is stamped when
    /// the pixels come back, which is *after* the clear. The epoch is stamped
    /// when the capture is requested, which is the question actually being asked.
    private var clearEpoch = 0
    private var lastAttempt: [String: Date] = [:]
    private var refreshTimer: Timer?

    /// pid → Accessibility observer watching that app's windows.
    private var axObservers: [pid_t: AXObserver] = [:]

    /// Rapid ⌘Tab through six apps fires six activate and six deactivate
    /// notifications in under a second. Without a floor, that is twelve
    /// screenshots for information that has not changed.
    private let minimumInterval: TimeInterval = 2

    /// How often the frontmost app's window is re-captured. This is the bound on
    /// how stale a card can be after an unannounced minimize, so it trades
    /// directly against idle cost — a single window screenshot every 20s.
    private let refreshInterval: TimeInterval = 20

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("Recents/windows", isDirectory: true)
        // 0700: this directory holds screenshots of the user's own windows, and
        // `~/Library/Caches` is not somewhere TCC protects the way it protects
        // the shared file lists this app reads. Set on an existing directory as
        // well as a new one, so a cache created by an earlier build is tightened
        // rather than left world-readable.
        try? FileManager.default.createDirectory(
            at: diskDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: diskDirectory.path
        )
        loadFromDiskInBackground()
    }

    // MARK: - Permissions

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt. Returns immediately; macOS requires a relaunch
    /// before a newly granted permission takes effect for this process.
    @discardableResult
    func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Accessibility is optional. It buys one thing: knowing the moment a window
    /// is deminiaturized, so the card refreshes instead of showing the frame from
    /// before it was minimized.
    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Lifecycle

    func start() {
        let center = NSWorkspace.shared.notificationCenter

        // Deactivation is the key moment: the user is switching away, the window
        // still holds the state they last saw, and it is about to be hidden.
        observers.append(observe(center, NSWorkspace.didDeactivateApplicationNotification) { app in
            Self.shared.capture(app: app, reason: .deactivated)
        })

        // Also capture on activation, so an app the user is returning to gets a
        // fresh thumbnail even if it was never deactivated while we were running.
        //
        // Twice, because activation and a window are not the same event. An app
        // brought forward with nothing open makes a window in response — Safari
        // does it from the Dock, ⌘N does it anywhere — and that window does not
        // exist yet at the instant activation is announced. The capture above
        // finds nothing, and without a second look the card would go on showing
        // the last frame from whenever the app last had a window, however many
        // hours ago that was, while its subtitle said the app was used a minute
        // ago. Accessibility catches the same case precisely; this is the floor
        // under machines where that permission was never granted.
        observers.append(observe(center, NSWorkspace.didActivateApplicationNotification) { app in
            Self.shared.capture(app: app, reason: .activated)
            Self.shared.captureAfterSettling(app: app, delay: 0.7, reason: .appeared)
        })

        // Hiding (⌘H) removes every window at once. Unlike miniaturization it is
        // announced, so there is still a frame to take — but only just, hence the
        // capture running before the windows are ordered out on the next pass.
        observers.append(observe(center, NSWorkspace.didHideApplicationNotification) { app in
            Self.shared.capture(app: app, reason: .hidden)
        })

        observers.append(observe(center, NSWorkspace.didUnhideApplicationNotification) { app in
            Self.shared.captureAfterSettling(app: app)
        })

        // A launching app has no window yet; give it a moment to draw one.
        observers.append(observe(center, NSWorkspace.didLaunchApplicationNotification) { app in
            Self.shared.installAccessibilityObserver(for: app)
            Self.shared.captureAfterSettling(app: app, delay: 2.0)
        })

        // Termination deliberately does *not* clear anything. The whole point of
        // the disk cache is that a quit app still shows the last screen we saw.
        observers.append(observe(center, NSWorkspace.didTerminateApplicationNotification) { app in
            Self.shared.removeAccessibilityObserver(for: app.processIdentifier)
        })

        for app in Self.regularApplications() {
            installAccessibilityObserver(for: app)
        }

        // Accessibility can be granted while this app is already running, and
        // `installAccessibilityObserver` returns early when the permission is
        // not yet there. Without this, granting it mid-session installed an
        // observer on nothing that was already open: the deminiaturize refresh
        // stayed dead until every app was quit and reopened, while Settings —
        // which re-reads the permission on activation — said it was granted.
        //
        // Returning from System Settings is precisely when this app becomes
        // active again, so that is the moment to sweep.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Self.shared.installMissingAccessibilityObservers()
            }
        }

        startRefreshTimer()

        // Seed from whatever is already on screen at launch.
        Task { await captureAllVisible() }
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        // `Array`: `removeAccessibilityObserver` mutates the dictionary these
        // keys are a live view of.
        for pid in Array(axObservers.keys) { removeAccessibilityObserver(for: pid) }
    }

    private func observe(
        _ center: NotificationCenter, _ name: NSNotification.Name,
        _ handler: @escaping (NSRunningApplication) -> Void
    ) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            MainActor.assumeIsolated { handler(app) }
        }
    }

    /// Keeps the frontmost app's frame fresh.
    ///
    /// macOS posts nothing before a window is miniaturized, so "capture
    /// immediately before minimization" is not available to any app. That used to
    /// matter a great deal; it matters much less now that `WindowServerCapture`
    /// can read a minimized window directly. This remains as the floor under the
    /// cases that path does not cover — an app with no titled window, or a
    /// machine where the SPI is gone — bounding how stale a surviving frame can
    /// be to `refreshInterval`.
    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let front = NSWorkspace.shared.frontmostApplication else { return }
                Self.shared.capture(app: front, reason: .periodic)
            }
        }
        // Common modes: otherwise the timer stalls for as long as a menu is open
        // or a window is being dragged, which is exactly when apps get minimized.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Reading captures

    func capture(forBundleID bundleID: String) -> Capture? { captures[bundleID] }

    /// What a click on a remembered still can honestly promise.
    ///
    /// A still is a picture of a window that is not there any more, so clicking
    /// it cannot lead back to what is in the picture: at best the document it
    /// shows is reopened, and otherwise the app simply starts a new, empty
    /// window. Both surfaces that show a still — the deck's cards and the Dock's
    /// hover panel — say this on hover, in these words, because it is the same
    /// promise in both places and two wordings would eventually disagree.
    static func openPromise(document: URL?) -> String {
        guard let document else { return "Opens in a new window" }
        return "Opens \(document.lastPathComponent)"
    }

    func image(forBundleID bundleID: String) -> NSImage? { captures[bundleID]?.image }

    /// Whether an app's capture is current or remembered.
    ///
    /// Called from card bodies, which SwiftUI re-evaluates on every frame of a
    /// scrub — a dozen cards at 60fps. Answering it from scratch each time meant
    /// a `CGWindowListCopyWindowInfo` and a LaunchServices lookup per card per
    /// frame, so the answer is computed for every app at once and held for a
    /// second. A card being a beat late to notice a window closed is invisible;
    /// the syscall storm was not.
    func presence(forBundleID bundleID: String) -> Presence {
        refreshPresenceIfStale()
        if liveBundleIDs.contains(bundleID) { return .live }
        if runningBundleIDs.contains(bundleID) { return .noVisibleWindow }
        return .notRunning
    }

    private var liveBundleIDs: Set<String> = []
    private var runningBundleIDs: Set<String> = []
    private var presenceComputedAt: Date = .distantPast
    private let presenceLifetime: TimeInterval = 1

    private func refreshPresenceIfStale() {
        guard Date().timeIntervalSince(presenceComputedAt) >= presenceLifetime else { return }
        presenceComputedAt = Date()

        let onScreen = Self.pidsWithOnScreenWindows()
        var live: Set<String> = []
        var running: Set<String> = []

        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            running.insert(bundleID)
            if onScreen.contains(app.processIdentifier) { live.insert(bundleID) }
        }

        liveBundleIDs = live
        runningBundleIDs = running
    }

    /// Re-captures every app that currently has a window on screen.
    ///
    /// Called when the deck is summoned: the user is about to look at these
    /// cards, so it is the one moment where spending a few screenshots is
    /// obviously worth it.
    func refreshVisible() {
        guard hasPermission else { return }
        Task { await captureAllVisible() }
    }

    // MARK: - Capture

    private enum Reason {
        case activated, deactivated, hidden, restored, periodic, seed
        /// A window that was not there a moment ago is there now — created, or
        /// drawn in the beat after its app was brought forward.
        case appeared

        /// Whether this reason overrules the rate floor.
        ///
        /// The floor exists to collapse bursts of redundant captures. A window
        /// arriving is not redundant: it is precisely the moment the remembered
        /// frame is known to be wrong, and it lands well inside the floor's two
        /// seconds of the activation that preceded it.
        var ignoresRateFloor: Bool {
            switch self {
            case .restored, .appeared: return true
            default: return false
            }
        }
    }

    private func capture(app: NSRunningApplication, reason: Reason) {
        guard hasPermission,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              Self.isCaptureAllowed(bundleID: bundleID),
              !inFlight.contains(bundleID)
        else { return }

        if !reason.ignoresRateFloor, let last = lastAttempt[bundleID],
           Date().timeIntervalSince(last) < minimumInterval {
            return
        }

        inFlight.insert(bundleID)
        lastAttempt[bundleID] = Date()
        let pid = app.processIdentifier
        let epoch = clearEpoch

        Task { [weak self] in
            // `defer`, not a call placed after the await.
            //
            // The insert above is what stops two captures of one app running at
            // once, and every path out of this task has to undo it. When the
            // window-server call could hang indefinitely, an app whose capture
            // wedged stayed in `inFlight` for the rest of the session and was
            // never photographed again. The call is bounded now — see
            // `WindowServerCapture.imageAsync` — and this makes the bookkeeping
            // survive any other early exit too.
            defer { self?.inFlight.remove(bundleID) }

            let result = await Self.captureFrontWindow(pid: pid)
            // A failed capture leaves the previous one in place. An app with no
            // capturable window right now is the ordinary case, not an error, and
            // dropping the last good frame on it is the bug this guards.
            guard let result else { return }
            // This screenshot was asked for before the user emptied the cache,
            // so it depicts the world they just cleared — see `clearEpoch`.
            guard self?.clearEpoch == epoch else { return }
            self?.store(result, for: bundleID)
        }
    }

    /// One delayed capture per app at a time.
    ///
    /// Window creation is announced per window, and an app restoring a session
    /// opens them in a burst. Coalescing means a dozen windows cost one capture —
    /// and it is the right one, since the capture picks the largest window at the
    /// moment it runs rather than the window that happened to announce itself.
    private var settling: Set<String> = []

    private func captureAfterSettling(
        app: NSRunningApplication, delay: TimeInterval = 0.5, reason: Reason = .restored
    ) {
        guard let bundleID = app.bundleIdentifier, !settling.contains(bundleID) else { return }
        settling.insert(bundleID)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.settling.remove(bundleID)
            self.capture(app: app, reason: reason)
        }
    }

    /// Snapshot every app that currently has an on-screen window.
    private func captureAllVisible() async {
        guard hasPermission else { return }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        ) else { return }

        // One window per app — the largest, which is almost always the document
        // window rather than a palette or toolbar.
        var best: [pid_t: SCWindow] = [:]
        for window in content.windows where Self.isCapturable(window) {
            guard let owner = window.owningApplication else { continue }
            let pid = owner.processID
            if let existing = best[pid], Self.area(existing) >= Self.area(window) { continue }
            best[pid] = window
        }

        // This loop awaits a capture per application, so it can still be running
        // well after it started. Anything it produces from before a clear is
        // discarded rather than written back — see `clearEpoch`.
        let epoch = clearEpoch

        for (pid, window) in best {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier
            else { continue }

            if let result = await Self.capture(window: window) {
                guard clearEpoch == epoch else { return }
                store(result, for: bundleID)
                lastAttempt[bundleID] = Date()
            }
        }
    }

    private static func captureFrontWindow(pid: pid_t) async -> Capture? {
        // Window-server path first. It is roughly an order of magnitude cheaper
        // than spinning up a capture stream, and unlike ScreenCaptureKit it
        // answers for a window that is minimized or hidden — which is exactly
        // when a card most needs a fresh frame rather than a remembered one.
        if let capture = await captureViaWindowServer(pid: pid) { return capture }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        ) else { return nil }

        let candidates = content.windows
            .filter { $0.owningApplication?.processID == pid && isCapturable($0) }
            .sorted { area($0) > area($1) }

        guard let window = candidates.first else { return nil }
        return await capture(window: window)
    }

    /// A still read straight from the window server, valid whether or not the
    /// window is on screen.
    private static func captureViaWindowServer(pid: pid_t) async -> Capture? {
        guard WindowServerCapture.isAvailable else { return nil }

        let windows = WindowServerCapture.candidateWindows().filter { $0.pid == pid }
        // A little longer than the live-preview path's deadline: a still is not
        // racing a 15fps tick, and a minimized window's first read after a while
        // is the slowest case there is. Bounded all the same — an unbounded wait
        // here is what used to strand an app in `inFlight` permanently.
        guard let reference = WindowServerCapture.bestWindowPerProcess(from: windows)[pid],
              let live = await WindowServerCapture.imageAsync(
                  ofWindow: reference.id, timeout: 0.6
              ),
              // Detached for the same reason `adoptLiveFrame` detaches: this
              // frame is the window's own backing store, and it is about to be
              // kept for as long as the app remembers anything about this app.
              let image = detached(live)
        else { return nil }

        // The ratio is derived from this window's own reported size rather than
        // assumed to be the display's backing scale, so a window living on a
        // non-Retina display is not silently halved.
        let width = max(reference.bounds.width, 1)
        let scale = max((CGFloat(image.width) / width).rounded(), 1)

        return Capture(
            image: NSImage(
                cgImage: image,
                size: NSSize(
                    width: CGFloat(image.width) / scale,
                    height: CGFloat(image.height) / scale
                )
            ),
            capturedAt: Date(),
            windowTitle: reference.title,
            sourceSize: reference.bounds.size,
            pixelSize: CGSize(width: image.width, height: image.height),
            // Asked here, while the window is still there to ask. This is the
            // path every per-app capture tries first, so it is where the
            // document of a window gets recorded for apps nobody has hovered a
            // preview of yet — Word among them, whose windows report no title to
            // the window server at all and so cannot be matched back to a file
            // by name afterwards.
            documentURL: DockWindows.document(of: reference)
        )
    }

    /// Writes a frame produced by the live-preview engine through to the
    /// persistent cache.
    ///
    /// Live previews are the reason a card moves, but they vanish with the deck.
    /// Folding the occasional one back into the on-disk cache is what makes the
    /// *still* the card falls back to — after the app quits, or on the next cold
    /// launch — a recent one rather than whatever the periodic timer last managed
    /// to catch. The engine throttles how often it calls this; it is not meant to
    /// run at frame rate.
    func adoptLiveFrame(
        _ image: NSImage?, for bundleID: String,
        window: WindowServerCapture.WindowRef?
    ) {
        guard let live = image else { return }

        // Copied, not adopted. A frame that arrives here from
        // `LiveWindowPreview` came out of `SLSHWCaptureWindowList`, which hands
        // back the window's *own* backing store rather than a copy of it — that
        // is precisely what makes a live thumbnail of a minimized window
        // possible. Keeping that image in a cache designed to outlive the
        // window keeps the window's surface alive with it, and the window server
        // will not let go of a window while anything holds its surface: the
        // window stayed in `CGWindowListCopyWindowInfo` after being closed,
        // indefinitely, so a closed window remained indistinguishable from a
        // minimized one everywhere downstream. Detaching costs one blit per
        // frame actually persisted, which is at most one per subject per
        // `persistInterval`.
        guard let image = Self.detached(live) else { return }

        // Read the true pixel count off the representation rather than inferring
        // it from a presumed 2× scale: `StoredMetadata` uses it to reconstruct
        // the point size on reload, and guessing here would make every capture
        // come back the wrong size on a non-Retina display.
        let representation = image.representations.first
        let pixelSize = CGSize(
            width: representation.map { CGFloat($0.pixelsWide) } ?? image.size.width,
            height: representation.map { CGFloat($0.pixelsHigh) } ?? image.size.height
        )

        let sourceSize = window?.bounds.size ?? .zero
        store(
            Capture(
                image: image,
                capturedAt: Date(),
                windowTitle: window?.title,
                sourceSize: sourceSize == .zero ? image.size : sourceSize,
                pixelSize: pixelSize,
                documentURL: window.flatMap { documentURL(of: $0, for: bundleID) }
            ),
            for: bundleID,
            notifying: false
        )
    }

    /// Which file a window has open, reused from the last capture whenever the
    /// window is still showing the same thing.
    ///
    /// The read itself is an Accessibility round trip into another process, made
    /// on the main thread and bounded rather than free, so it is worth not
    /// repeating: a window's document does not change while its title stays the
    /// same, which means an app whose preview is on screen pays for this once
    /// per document rather than once every `persistInterval`.
    private func documentURL(
        of window: WindowServerCapture.WindowRef, for bundleID: String
    ) -> URL? {
        if let previous = captures[bundleID], previous.windowTitle == window.title,
           let document = previous.documentURL {
            return document
        }
        return DockWindows.document(of: window)
    }

    /// A copy of an image that shares nothing with what it was made from.
    ///
    /// Drawn into a fresh bitmap rather than passed through `CGImage.copy()`,
    /// which is free to keep referencing the original's data provider — and the
    /// data provider is the thing that must be let go of here.
    private static func detached(_ image: NSImage) -> NSImage? {
        guard let source = image.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ), let copy = detached(source) else { return nil }
        return NSImage(cgImage: copy, size: image.size)
    }

    /// The same copy, one level down. Every frame that came from
    /// `WindowServerCapture` and is about to be *kept* passes through here.
    private static func detached(_ source: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: source.width,
            height: source.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            // The source's own space where it has one, so a wide-gamut window
            // is not quietly squeezed into sRGB on its way into the cache.
            space: source.colorSpace
                ?? CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(
            source,
            in: CGRect(x: 0, y: 0, width: source.width, height: source.height)
        )
        return context.makeImage()
    }

    /// Ceiling on captured pixels per window.
    ///
    /// A 6K display's full-screen window at 2× is 12 megapixels; a dozen of those
    /// cached in memory and on disk costs far more than the card can ever show.
    /// 2600px on the long edge is still ~7× the 378pt app card's width at 2×.
    private static let maximumCapturedEdge: CGFloat = 2600

    private static func capture(window: SCWindow) async -> Capture? {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        // Capture at the display's true backing resolution. The previous version
        // computed `min(1, backingScale / 2)`, which is 1.0 on every Retina Mac —
        // it captured a Retina window at half its pixels and then drew the result
        // enlarged, which is where the softness came from.
        let backingScale = await MainActor.run { DeckScreen.backingScale }
        var pixelWidth = window.frame.width * backingScale
        var pixelHeight = window.frame.height * backingScale

        let longest = max(pixelWidth, pixelHeight)
        if longest > maximumCapturedEdge {
            let factor = maximumCapturedEdge / longest
            pixelWidth *= factor
            pixelHeight *= factor
        }

        let config = SCStreamConfiguration()
        config.width = max(Int(pixelWidth.rounded()), 1)
        config.height = max(Int(pixelHeight.rounded()), 1)
        config.scalesToFit = true
        config.showsCursor = false
        config.captureResolution = .best

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) else { return nil }

        // Point size, not pixel size: the same honesty about resolution that the
        // document thumbnails rely on, so the card can decline to enlarge a
        // capture past what was actually recorded.
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: CGFloat(cgImage.width) / backingScale,
                height: CGFloat(cgImage.height) / backingScale
            )
        )

        return Capture(
            image: image,
            capturedAt: Date(),
            windowTitle: window.title,
            sourceSize: window.frame.size,
            pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }

    /// Skips the chrome that would make a useless thumbnail: menu bar, Dock,
    /// tiny palettes, and off-screen or zero-size windows.
    private static func isCapturable(_ window: SCWindow) -> Bool {
        guard window.isOnScreen,
              window.frame.width >= 200, window.frame.height >= 150,
              window.windowLayer == 0
        else { return false }

        if let id = window.owningApplication?.bundleIdentifier {
            if id == "com.apple.dock" || id == "com.apple.systemuiserver" { return false }
            if !isCaptureAllowed(bundleID: id) { return false }
        }
        return true
    }

    /// Apps whose windows are never photographed, however capturable they are.
    ///
    /// The rest of this class asks whether a window makes a *useful* thumbnail.
    /// This asks a different question: whether a still of it should exist on
    /// disk at all. `SecurityAgent` is the process that draws the "enter your
    /// password" sheet, and while the field itself renders as bullets, the
    /// dialog is a durable record of what was being authorised and when.
    /// Credential managers are the same case with the contents in plain text.
    ///
    /// Matched on prefix as well as exact identifier, because the
    /// authentication surfaces come in families — `com.apple.SecurityAgent`,
    /// its plugins, and the several login and local-authentication agents.
    nonisolated private static let deniedBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.systemuiserver",
        "com.apple.dock",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.apple.PasswordBreachAgent",
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.1password.1password",
        "com.1password.1password-launcher",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword4",
        "com.bitwarden.desktop",
        "com.dashlane.Dashlane",
        "com.lastpass.LastPass",
        "com.callpod.keeper-mac",
        "in.sinew.Enpass-Desktop",
        "org.keepassxc.keepassxc",
        "com.strongbox.mac.strongbox",
    ]

    nonisolated private static let deniedBundlePrefixes: [String] = [
        "com.apple.SecurityAgent",
        "com.apple.CoreAuthUI",
        "com.apple.LocalAuthentication",
        "com.apple.AuthKit",
        "com.apple.SecurityAgentPlugin",
    ]

    /// Whether this app may be captured at all. Checked wherever a bundle
    /// identifier is known, not only in `isCapturable` — the window-server path,
    /// the live-preview write-through and the disk cache all reach `store()`
    /// without ever seeing an `SCWindow`.
    nonisolated static func isCaptureAllowed(bundleID: String) -> Bool {
        guard !deniedBundleIDs.contains(bundleID) else { return false }
        return !deniedBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    private static func area(_ window: SCWindow) -> CGFloat {
        window.frame.width * window.frame.height
    }

    /// Which processes have a real window on screen right now.
    ///
    /// Deliberately `CGWindowListCopyWindowInfo` rather than ScreenCaptureKit:
    /// window geometry and ownership are not privileged, so this answers even
    /// without Screen Recording — which matters, because it is what tells a card
    /// whether it is showing a live app or a remembered one.
    private static func pidsWithOnScreenWindows() -> Set<pid_t> {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var pids: Set<pid_t> = []
        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 200, (bounds["Height"] ?? 0) >= 150
            else { continue }
            pids.insert(pid)
        }
        return pids
    }

    private static func regularApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
    }

    // MARK: - Accessibility

    /// Watches one app for windows appearing, miniaturizing and coming back.
    ///
    /// Deminiaturize is the moment the pixels come back, and the cue to replace a
    /// remembered frame with a live one. Creation is the same cue for a window
    /// that did not exist at all — the case that leaves an app the user just
    /// opened wearing a screenshot from hours ago, because nothing else in this
    /// class fires when a window arrives on its own. The miniaturize half is
    /// registered anyway because it is the cheapest way to learn that a card has
    /// gone from live to remembered, which the deck shows.
    private func installAccessibilityObserver(for app: NSRunningApplication) {
        guard hasAccessibilityPermission,
              app.activationPolicy == .regular,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }

        let pid = app.processIdentifier
        guard axObservers[pid] == nil else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, axNotificationCallback, &observer) == .success,
              let observer
        else { return }

        let element = AXUIElementCreateApplication(pid)
        let context = UnsafeMutableRawPointer(bitPattern: Int(pid))

        for name in [
            kAXWindowCreatedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ] {
            AXObserverAddNotification(observer, element, name as CFString, context)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode
        )
        axObservers[pid] = observer
    }

    /// Installs an observer on every eligible app that does not already have
    /// one. Idempotent and cheap — `installAccessibilityObserver` returns
    /// immediately for an app already covered — so it is safe to run on every
    /// activation rather than only when `axObservers` is empty, which also
    /// covers apps launched during a window where the permission was absent.
    private func installMissingAccessibilityObservers() {
        guard hasAccessibilityPermission else { return }
        for app in Self.regularApplications() {
            installAccessibilityObserver(for: app)
        }
    }

    private func removeAccessibilityObserver(for pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode
        )
    }

    fileprivate func handleAccessibilityEvent(_ notification: String, pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }

        switch notification {
        case kAXWindowDeminiaturizedNotification:
            // The window is coming back; let it finish animating before reading it.
            captureAfterSettling(app: app, delay: 0.45)

        case kAXWindowCreatedNotification:
            // Announced the instant the window exists, which is before it has
            // drawn anything. Read it once it has.
            captureAfterSettling(app: app, delay: 0.45, reason: .appeared)

        case kAXWindowMiniaturizedNotification:
            // Nothing to capture — the pixels are already unavailable. Just tell
            // the deck, so a card can say it is showing a remembered frame.
            generation &+= 1
            onUpdate?()

        default:
            break
        }
    }

    // MARK: - Persistence

    /// - Parameter notifying: false when the caller is the live-preview engine,
    ///   which already has the frame on screen through its own slot. Bumping the
    ///   generation there would invalidate every card on the rail to deliver a
    ///   still that one card is already showing a better version of.
    private func store(_ capture: Capture, for bundleID: String, notifying: Bool = true) {
        guard Self.isCaptureAllowed(bundleID: bundleID) else { return }

        // A capture taken by a path that does not read documents —
        // ScreenCaptureKit — must not erase what an earlier one established
        // about the same window. The title is what says it is the same window,
        // which is also why an untitled window inherits nothing: Word reports no
        // title for any of its windows, so "same title" there would mean "some
        // other Word document" as readily as this one, and promising to reopen
        // the wrong file is worse than promising nothing.
        var capture = capture
        if capture.documentURL == nil,
           let title = capture.windowTitle, !title.isEmpty,
           let previous = captures[bundleID], previous.windowTitle == title {
            capture.documentURL = previous.documentURL
        }

        captures[bundleID] = capture
        if notifying {
            generation &+= 1
            onUpdate?()
        }

        // Persisted so an app that has not run since launch still shows the last
        // window we ever saw from it.
        //
        // Encoded and written on `diskQueue`, not here. A capture is up to
        // 2600px on its long edge, and PNG-encoding one of those is tens of
        // milliseconds of the main thread — spent, for the periodic refresh,
        // while the user is doing something else entirely.
        let image = capture.image
        let metadata = StoredMetadata(capture, bundleID: bundleID)
        let imageURL = imageURL(for: bundleID)
        let metadataURL = metadataURL(for: bundleID)

        Self.diskQueue.async {
            if let png = image.pngData() {
                try? png.write(to: imageURL, options: .atomic)
                Self.restrictPermissions(of: imageURL)
            }
            if let json = try? JSONEncoder().encode(metadata) {
                try? json.write(to: metadataURL, options: .atomic)
                Self.restrictPermissions(of: metadataURL)
            }
        }
    }

    /// One serial queue for every read and write of the capture cache, so the
    /// main thread never waits on image encoding or file I/O and writes for the
    /// same app cannot interleave.
    nonisolated private static let diskQueue = DispatchQueue(
        label: "com.recents.deck.capturecache", qos: .utility
    )

    /// A window capture is a screenshot of the user's work. `0600` on the files
    /// and `0700` on the directory keeps it readable only by this user, rather
    /// than by anything running on the machine, which is what the `0644` default
    /// on an atomic write would give.
    nonisolated private static func restrictPermissions(of url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    /// The sidecar written next to each PNG. Kept separate from the image so the
    /// bitmap stays a plain PNG anything can open, and so a metadata format change
    /// degrades to "we know less about this capture" rather than losing it.
    private struct StoredMetadata: Codable {
        var capturedAt: Date
        var windowTitle: String?
        var sourceWidth: CGFloat
        var sourceHeight: CGFloat
        var pixelWidth: CGFloat
        var pixelHeight: CGFloat
        /// Pixels per point in the stored bitmap. Recorded rather than assumed,
        /// because the capture ceiling means it is not always the display's
        /// backing scale — and because it is what reconstructs the image's point
        /// size on reload.
        var scale: CGFloat
        /// Which app this capture came from.
        ///
        /// Recorded because the filename is no longer guaranteed to say so: an
        /// identifier that is not a safe path component becomes a hash instead
        /// (see `fileStem(for:)`), and without this the capture could not be
        /// matched back to its app on reload. Optional so a sidecar written by
        /// an earlier build still reads.
        var bundleID: String?
        /// The file the captured window had open. Optional for the same reason
        /// as `bundleID`, and it is the common case on a cache written before
        /// documents were recorded at all — which is why the Dock panel can also
        /// work one back from the window title.
        var documentPath: String?

        init(_ capture: Capture, bundleID: String) {
            capturedAt = capture.capturedAt
            windowTitle = capture.windowTitle
            sourceWidth = capture.sourceSize.width
            sourceHeight = capture.sourceSize.height
            pixelWidth = capture.pixelSize.width
            pixelHeight = capture.pixelSize.height
            let points = max(capture.image.size.width, 1)
            scale = max(capture.pixelSize.width / points, 1)
            self.bundleID = bundleID
            documentPath = capture.documentURL?.path
        }
    }

    /// Reads the cache back, on `diskQueue`, and folds the result in when it
    /// lands.
    ///
    /// Decoding every cached PNG — tens of files, tens of megabytes — used to
    /// happen synchronously inside `init`, which runs on the first touch of
    /// `AppWindowCapture.shared` during `applicationDidFinishLaunching`. That put
    /// the whole cache squarely in the launch path. Nothing needs it before the
    /// deck is first summoned, and a capture taken in the meantime is newer than
    /// anything on disk, so it wins.
    private func loadFromDiskInBackground() {
        let directory = diskDirectory
        let epoch = clearEpoch
        Self.diskQueue.async { [weak self] in
            Self.pruneDisk(at: directory)
            let loaded = Self.loadCaptures(in: directory)
            guard !loaded.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.adopt(loaded, epoch: epoch) }
            }
        }
    }

    private func adopt(_ loaded: [String: Capture], epoch: Int) {
        // Read from disk before the user emptied the cache: those files are gone
        // now, and putting their images back in memory would leave cards showing
        // screenshots that no longer exist anywhere else.
        guard epoch == clearEpoch else { return }

        for (bundleID, capture) in loaded where captures[bundleID] == nil {
            captures[bundleID] = capture
        }
        generation &+= 1
        onUpdate?()
    }

    nonisolated private static func loadCaptures(in directory: URL) -> [String: Capture] {
        var loaded: [String: Capture] = [:]

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return loaded }

        for file in files where file.pathExtension == "png" {
            guard let rep = (try? Data(contentsOf: file)).flatMap(NSBitmapImageRep.init(data:))
            else { continue }

            let stem = file.deletingPathExtension().lastPathComponent
            let metadata = (try? Data(
                contentsOf: directory.appendingPathComponent(stem + ".json")
            )).flatMap { try? JSONDecoder().decode(StoredMetadata.self, from: $0) }

            // The sidecar is authoritative about which app this came from, since
            // the filename is a hash for any identifier that was not itself a
            // safe path component. Without a sidecar the stem is all there is,
            // and it is trusted only if it still looks like an identifier.
            guard let bundleID = metadata?.bundleID ?? (isSafeFileStem(stem) ? stem : nil),
                  isCaptureAllowed(bundleID: bundleID)
            else { continue }

            let pixelSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            // Reconstruct the point size from the recorded scale, so a capture
            // reloaded after relaunch reports the same resolution it had when it
            // was taken — and the no-upscale rule still applies to it. Without
            // the sidecar, assume 2×: wrong only on a non-Retina Mac, and wrong
            // in the safe direction (a slightly small preview, never a stretched
            // one).
            let scale = max(metadata?.scale ?? 2, 1)
            let pointSize = NSSize(
                width: pixelSize.width / scale, height: pixelSize.height / scale
            )

            let image = NSImage(size: pointSize)
            image.addRepresentation(rep)

            loaded[bundleID] = Capture(
                image: image,
                capturedAt: metadata?.capturedAt ?? .distantPast,
                windowTitle: metadata?.windowTitle,
                sourceSize: metadata.map { NSSize(width: $0.sourceWidth, height: $0.sourceHeight) }
                    ?? pointSize,
                pixelSize: pixelSize,
                documentURL: metadata?.documentPath.map { URL(fileURLWithPath: $0) }
            )
        }

        return loaded
    }

    /// How long a capture survives without being replaced.
    ///
    /// `ThumbnailCache` sweeps its renders after a month; this cache had no
    /// equivalent at all, so every window screenshot it ever took stayed on disk
    /// until the user pressed *Clear Captured Window Images*. A capture is a
    /// picture of whatever the user had open, and one that no longer backs any
    /// card — the app is gone, or has not been seen in a month — is only a
    /// record of what they were doing at the time.
    nonisolated private static let retention: TimeInterval = 60 * 60 * 24 * 30

    /// Sweeps expired captures, and any capture belonging to an app that is no
    /// longer allowed to be captured at all.
    ///
    /// The second half matters on upgrade: a cache written before the deny-list
    /// existed can hold a screenshot of the authentication sheet, and adding the
    /// rule without also applying it to what is already on disk would leave that
    /// there indefinitely.
    nonisolated private static func pruneDisk(at directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .contentAccessDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }

        let cutoff = Date().addingTimeInterval(-retention)

        for file in files {
            let stem = file.deletingPathExtension().lastPathComponent

            // Files written by an earlier build are `0644`. The directory above
            // them is `0700` now, so they are already out of reach, but a cache
            // that is only protected by its parent is one `chmod` away from
            // being readable again.
            restrictPermissions(of: file)

            let values = try? file.resourceValues(forKeys: Set(keys))
            let touched = values?.contentModificationDate
                ?? values?.contentAccessDate
                ?? .distantPast
            if touched < cutoff {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            // Only the PNG carries a decidable identity — its sidecar names the
            // app. A sidecar orphaned by its PNG's removal goes on the next
            // pass, when the sweep above catches it on age.
            guard file.pathExtension == "png" else { continue }

            let metadata = (try? Data(
                contentsOf: directory.appendingPathComponent(stem + ".json")
            )).flatMap { try? JSONDecoder().decode(StoredMetadata.self, from: $0) }
            let bundleID = metadata?.bundleID ?? stem

            if !isCaptureAllowed(bundleID: bundleID) {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(stem + ".json")
                )
            }
        }
    }

    private func imageURL(for bundleID: String) -> URL {
        diskDirectory.appendingPathComponent(Self.fileStem(for: bundleID) + ".png")
    }

    private func metadataURL(for bundleID: String) -> URL {
        diskDirectory.appendingPathComponent(Self.fileStem(for: bundleID) + ".json")
    }

    /// The filename a bundle identifier is allowed to become.
    ///
    /// A bundle identifier is not a safe path component. It is whatever string
    /// the app put in its `CFBundleIdentifier` — macOS does not validate the
    /// character set — and `appendingPathComponent` escapes nothing, so an app
    /// identifying itself as `../../../../tmp/evil` would have made this class
    /// write a PNG it controls, at a path it controls, anywhere this user can
    /// write. Screen Recording is the only thing that gates reaching here, and
    /// that is granted for the app's headline feature.
    ///
    /// Identifiers that look like identifiers are kept verbatim, because a cache
    /// directory of readable names is worth having. Anything else is replaced by
    /// the SHA-256 of the identifier — the same shape `ThumbnailCache.cacheKey`
    /// uses — which keeps the capture working for an app with an eccentric but
    /// harmless identifier instead of silently dropping it.
    nonisolated static func fileStem(for bundleID: String) -> String {
        if isSafeFileStem(bundleID) { return bundleID }
        let digest = SHA256.hash(data: Data(bundleID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Conservative by design: everything Apple's own rules allow in a bundle
    /// identifier, and nothing that can address a directory. No separators, no
    /// leading dot (which would both hide the file and open the `..` case), and
    /// a length that cannot overrun a filesystem name limit.
    nonisolated private static func isSafeFileStem(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.utf8.count <= 200,
              !candidate.hasPrefix(".")
        else { return false }

        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_+")
        return candidate.allSatisfy(allowed.contains)
    }

    func clearCaptures() {
        captures.removeAll()
        lastAttempt.removeAll()
        // Anything already requested belongs to the cache being emptied.
        clearEpoch &+= 1
        generation &+= 1

        // On `diskQueue`, so it is ordered *after* any capture already queued
        // for writing. Deleting the directory straight from here would let an
        // in-flight write land a moment later and put a file back into a cache
        // the user had just asked to be emptied.
        let directory = diskDirectory
        Self.diskQueue.async {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        onUpdate?()
    }
}

/// C callback for `AXObserver`. Must be a plain function value with no captured
/// state, so the pid rides along in the observer's refcon.
private let axNotificationCallback: AXObserverCallback = { _, _, notification, context in
    guard let context else { return }
    let pid = pid_t(Int(bitPattern: context))
    let name = notification as String
    // AXObserver run-loop sources are attached to the main run loop, so this
    // already runs on the main thread.
    MainActor.assumeIsolated {
        AppWindowCapture.shared.handleAccessibilityEvent(name, pid: pid)
    }
}
