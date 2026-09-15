import AppKit
import Observation
import SwiftUI

/// Live, moving previews of application windows — including windows that are
/// minimized, hidden, or buried behind other windows.
///
/// This is the macOS answer to a Windows taskbar thumbnail. Hovering a taskbar
/// button on Windows shows a DWM thumbnail that *keeps playing*: a video running
/// in a minimized window animates in the preview. A still screenshot taken at
/// some earlier moment is the thing that does not do that, and it is what the
/// deck used to show, so a playing video appeared frozen on a card.
///
/// One engine serves both surfaces that show such a preview — the deck's cards
/// and the Dock hover panel — because they are the same claim about the same
/// windows and must never disagree. What differs is only what they point at, and
/// that is the whole of `Subject`: a deck card stands for an *application* and
/// follows whichever window best represents it, while a Dock thumbnail stands
/// for one specific *window*, since hovering an app tile shows every window that
/// app owns and two of them may be minimized. Everything downstream — the
/// pacing, the frame deduplication, the blank-frame guard, the failure counting,
/// the write-through to the on-disk cache — is shared, so a window looks the
/// same in both places and costs the same in both places.
///
/// The engine is deliberately demand-driven and foreground-only:
///
///   • It runs only while some surface is on screen and has claimed it. Closed
///     deck and no Dock preview means no timer, no captures, nothing.
///   • Subscribers register the attention they are getting. The card at the
///     centre of the rail is `.focused` and refreshes at the full rate; cards
///     off to one side of it refresh at a fraction of that, and the rest of the
///     rail is not captured at all. A Dock panel has no periphery — it is six
///     thumbnails at most, all of them the reason it is open — so every window
///     in one is `.focused` for as long as it is up.
///   • A frame that is byte-for-byte unchanged is dropped before it reaches
///     SwiftUI, so a deck full of idle windows costs no redraws.
///
/// The pacing comes from measurement, not taste. A window-server capture costs
/// ~10.5 ms of wall time and ~0.2 ms of CPU, and the server serialises them, so
/// the scarce resource is the *number of calls per second*, not processor time.
/// Captures therefore run on one background serial queue — which keeps the
/// blocking round trip off the main thread, where the rail is animating at 60fps
/// — and the budget is spent on the one thing the user is actually looking at.
@MainActor
final class LiveWindowPreview {

    static let shared = LiveWindowPreview()

    /// What a subscriber is following.
    ///
    /// The two cases are not interchangeable and deliberately do not collapse
    /// into one. An application's best window changes as the user opens and
    /// closes things, and a deck card has to follow that change without
    /// resubscribing; a Dock thumbnail is showing one window and must never
    /// silently start showing a different one.
    enum Subject: Hashable {
        case application(String)
        case window(CGWindowID)
    }

    /// A surface that needs the engine running. The engine ticks while any of
    /// them is held and stops when the last one lets go, so neither surface can
    /// switch the other one off.
    enum Client: Hashable {
        case deck
        case dock
    }

    /// How much attention a subscriber is getting, which decides its refresh
    /// rate.
    enum Demand: Int, Comparable {
        /// Centred on the rail, or shown in a Dock panel. Refreshes every tick.
        case focused = 2
        /// On the rail but off to one side. Refreshes every `visibleDivisor` ticks.
        case visible = 1

        static func < (lhs: Demand, rhs: Demand) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One subscriber's live frame.
    ///
    /// A separate observable object per subject rather than one dictionary on
    /// the engine: with `@Observable`, a view that reads `slot.image` re-renders
    /// when *that* slot changes and not when any other frame lands. A single
    /// shared dictionary would invalidate every card on the rail sixty times a
    /// second.
    @Observable
    final class Slot {
        /// The most recent frame, or nil if nothing has been captured yet.
        var image: NSImage?
        /// True while frames are genuinely arriving for this subject right now.
        var isLive = false
        /// Whether the window this is coming from is minimized or otherwise off
        /// screen — which is worth saying, since the frame is live either way
        /// but the window is not somewhere the user can see it.
        var isOffScreen = false

        @ObservationIgnored fileprivate var frameHash: UInt64 = 0

        /// Lets the frame go, and with it the memory of which frame it was.
        ///
        /// The two have to go together. A capture whose hash matches
        /// `frameHash` is dropped on the capture queue as "unchanged" before
        /// anything on the main actor sees it — which is right while the frame
        /// it matches is still in `image`, and wrong from the moment that frame
        /// has been released: the window has nothing new to say, so it is never
        /// allowed to say anything again. A minimised document window is the
        /// worst case, because nothing ever changes in it. Measured: hover a Dock
        /// tile, hover two others, come back — every thumbnail a placeholder,
        /// for as long as the windows stayed minimised.
        fileprivate func dropFrame() {
            image = nil
            frameHash = 0
        }
        @ObservationIgnored fileprivate var lastArrival: Date = .distantPast
        /// When this subject was last *asked* for a frame, which is a different
        /// question from when one last arrived — see `scheduledSubjects`.
        @ObservationIgnored fileprivate var lastAttempt: Date = .distantPast
        @ObservationIgnored fileprivate var lastPersisted: Date = .distantPast
        /// Captures attempted for this subject that came back with nothing, since
        /// the last one that did not. See `failureTolerance`.
        @ObservationIgnored fileprivate var consecutiveFailures = 0
    }

    // MARK: - Tuning

    /// Full refresh rate for a focused subject. Video reads as motion well below
    /// display refresh, and every frame here is a serialised round trip to the
    /// window server, so this buys smoothness where it is noticed and spends
    /// nothing where it is not.
    private let ticksPerSecond: Double = 15

    /// Non-focused visible subjects refresh on every Nth tick — three times a
    /// second. Enough that a neighbouring card is visibly alive; cheap enough
    /// that a full rail does not saturate the capture channel.
    private let visibleDivisor = 5

    /// Ceiling on how many subjects may be captured in a single tick, focused
    /// ones first. Without it, a rail of a dozen running apps would queue more
    /// work per tick than a tick has time for.
    private let maximumPerTick = 4

    /// How often a live frame is also written through to the persistent capture
    /// cache, so quitting the app still leaves a recent still behind.
    private let persistInterval: TimeInterval = 15

    /// A slot with no frame for longer than this stops claiming to be live.
    private let liveTimeout: TimeInterval = 1.5

    /// Consecutive failed captures before a slot stops claiming to be live.
    ///
    /// "Nothing has changed" and "the capture channel is broken" look identical
    /// from the frame side — both are simply an absence of new frames — which is
    /// why a static window must not lose its badge for going quiet. They are
    /// easy to tell apart from the *attempt* side: a static window still returns
    /// an image, a broken channel returns nothing. Five in a row is a third of a
    /// second for a focused subject and under two seconds for a visible one, so
    /// a single hiccup never flickers the badge.
    private static let failureTolerance = 5

    // MARK: - State

    private var slots: [Subject: Slot] = [:]
    private var demands: [Subject: Demand] = [:]
    private var clients: Set<Client> = []

    private var timer: Timer?
    private var tick = 0
    private var isCapturing = false
    private var captureStartedAt: Date = .distantPast

    /// Comfortably longer than `maximumPerTick` captures at their own timeout,
    /// so this only ever fires on a genuine stall.
    private let captureWatchdog: TimeInterval = 4

    /// Where each subject's pixels currently come from. Rebuilt on a timer rather
    /// than per capture: enumerating every window on the system is far cheaper
    /// than a capture but not free, and a window's identity does not change
    /// between frames of a video.
    private var windowForBundle: [String: WindowServerCapture.WindowRef] = [:]
    private var windowByID: [CGWindowID: WindowServerCapture.WindowRef] = [:]
    private var windowMapRefreshedAt: Date = .distantPast
    private let windowMapLifetime: TimeInterval = 1

    /// Every running application's bundle identifier, by process.
    ///
    /// Held rather than re-read on each window-map refresh, because reading it
    /// is not the lookup it looks like. `NSWorkspace.runningApplications` hands
    /// back objects whose properties are fetched lazily, and the first
    /// `processIdentifier` or `bundleIdentifier` read on each is a LaunchServices
    /// round trip. Walked once a second from `refreshWindowMap`, fifty
    /// applications came to ~10 ms of the main thread — every second, for as
    /// long as any preview was on screen, and visible as a regular hitch in
    /// whatever the pointer was doing.
    ///
    /// Nil when the set of running applications has changed since it was last
    /// built, which the workspace announces through KVO; rebuilt on the next
    /// refresh that needs it.
    private var bundleIDsByPID: [pid_t: String]?
    private var runningApplicationsObserver: NSKeyValueObservation?

    private let queue = DispatchQueue(
        label: "com.recents.deck.livepreview", qos: .userInitiated
    )

    /// The priming batch still in flight, so a newer one — or a surface going
    /// away — can call it off.
    ///
    /// A pointer browsing along the Dock builds a panel per tile, and each of
    /// them primes up to six captures outside the tick budget. Those serialise
    /// behind each other on the capture queue, so by the time the user settles
    /// the frames they are waiting for are queued behind two or three tiles'
    /// worth of pictures that `deliver` will refuse on arrival — it drops any
    /// frame nothing is following any more. Cancelling is what stops that work
    /// being *done* rather than merely thrown away afterwards.
    private var primeBatch: CaptureBatch?

    /// A cancellation flag the capture queue can read while the main actor sets
    /// it.
    ///
    /// `DispatchWorkItem` would do, but only between work items: a priming batch
    /// is six captures inside one block and up to half a second long, so it has
    /// to be able to give up part way through. A lock rather than an actor,
    /// because it is read between captures on the capture queue and written on
    /// the main one, and neither side can afford to await the other.
    final class CaptureBatch: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private init() {
        // Hopped onto the main queue rather than assumed to be there: the
        // workspace posts this from the main thread today, and the cost of
        // being wrong about that would be a trap, not a stale map for a tick.
        runningApplicationsObserver = NSWorkspace.shared.observe(
            \.runningApplications, options: []
        ) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { LiveWindowPreview.shared.bundleIDsByPID = nil }
            }
        }
    }

    /// Pays the engine's cold costs ahead of the first surface that needs it:
    /// the process table and the window list, each a round trip the first time.
    func warmUp() {
        refreshWindowMap()
    }

    /// Whether live previews can work at all: the private capture path has to be
    /// present.
    var isSupported: Bool { WindowServerCapture.isAvailable }

    /// Whether the engine should be ticking: the path exists, Screen Recording
    /// is granted, and at least one of the two surfaces the user can switch on
    /// is switched on.
    var isEnabled: Bool {
        isSupported
            && AppWindowCapture.shared.hasPermission
            && (Preferences.shared.livePreviews || Preferences.shared.dockPreviews)
    }

    // MARK: - Lifecycle

    /// Claims the engine for a surface that has come on screen. Idempotent.
    func retain(_ client: Client) {
        clients.insert(client)
        start()
    }

    /// Releases a surface's claim. The engine stops once nobody is holding it —
    /// nothing runs in the background on behalf of a window nobody is looking at.
    func release(_ client: Client) {
        clients.remove(client)
        if clients.isEmpty { stop() }
    }

    private func start() {
        guard isEnabled, timer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: 1 / ticksPerSecond, repeats: true
        ) { _ in
            MainActor.assumeIsolated { LiveWindowPreview.shared.fire() }
        }
        // Common modes, so the previews keep moving while a menu is open or the
        // window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Registered demand is deliberately *kept*. Ordering a window out does not
    /// fire SwiftUI's `onDisappear`, so the deck's cards never get a chance to
    /// re-register — clearing the table here meant that reopening the deck showed
    /// no live previews at all until the user happened to scrub the rail and
    /// change a card's attention. Subscribers prune their own entries when they
    /// really do go away.
    private func stop() {
        timer?.invalidate()
        timer = nil
        isCapturing = false
        for slot in slots.values {
            slot.isLive = false
            slot.consecutiveFailures = 0
        }
    }

    /// Reflects a settings change without waiting for a surface to be reopened.
    ///
    /// The claims are deliberately left alone. A surface that is on screen is
    /// still on screen after a preference changes, so it goes on holding the
    /// engine; `start()` is what re-reads `isEnabled` and decides whether the
    /// timer comes back. Switched off, every frame is dropped as well as the
    /// timer — a slot left holding its last picture would be a "live" preview
    /// frozen at the moment the user turned the feature off.
    func reload() {
        stop()
        if !clients.isEmpty { start() }
        if !isEnabled {
            for slot in slots.values { slot.dropFrame() }
        }
    }

    // MARK: - Subscription

    /// The slot a subscriber should read from. Creating it is cheap and
    /// idempotent, so a view can ask for one every time it appears.
    func slot(for subject: Subject) -> Slot {
        if let existing = slots[subject] { return existing }
        let slot = Slot()
        slots[subject] = slot
        return slot
    }

    /// Declares how much attention a subject is getting. Passing nil
    /// unsubscribes.
    func setDemand(_ demand: Demand?, for subject: Subject) {
        if let demand {
            demands[subject] = demand
        } else {
            demands.removeValue(forKey: subject)
            slots[subject]?.isLive = false
            // A fresh subscription starts from a clean slate, so a subscriber
            // coming back is not immediately un-badged by failures from last time.
            slots[subject]?.consecutiveFailures = 0
        }
    }

    /// Convenience for the deck's cards, which think in applications.
    func slot(for bundleID: String) -> Slot { slot(for: .application(bundleID)) }

    func setDemand(_ demand: Demand?, for bundleID: String) {
        setDemand(demand, for: .application(bundleID))
    }

    /// Convenience for the Dock panel, which thinks in windows.
    func slot(forWindow id: CGWindowID) -> Slot { slot(for: .window(id)) }

    func setDemand(_ demand: Demand?, forWindow id: CGWindowID) {
        setDemand(demand, for: .window(id))
    }

    /// Drops every window subscription at once.
    ///
    /// The Dock panel is torn down wholesale rather than thumbnail by thumbnail
    /// — the pointer leaves and the whole thing goes — and a thumbnail that was
    /// removed without its `onDisappear` running would otherwise leave demand
    /// behind for a window nobody is looking at.
    func clearWindowDemands() {
        // `Array`: the loop body mutates the dictionary that `keys` is a live
        // view of.
        var released: Set<Subject> = []
        for subject in Array(demands.keys) where isWindow(subject) {
            demands.removeValue(forKey: subject)
            slots[subject]?.isLive = false
            slots[subject]?.consecutiveFailures = 0
            released.insert(subject)
        }

        // The frames just released are kept, and every older one is dropped.
        //
        // Keeping them is the deliberate part, and it is why the slots survive
        // this at all: a panel re-forming around a closed window, or the pointer
        // going back to the tile it just left, redraws complete instead of
        // filling in a frame at a time. Keeping *every* frame ever captured is
        // the part that was not intended. A frame is not merely bytes — see
        // `forgetWindow` — it is the window's own backing store, and holding one
        // keeps the window server's copy of that window alive behind it. Every
        // window of every tile hovered in a session was being held that way for
        // as long as Recents ran, which grows this process without bound and
        // keeps other applications' closed windows resident along with it.
        //
        // One panel's worth is the bound, because one panel back is as far as
        // "the tile I just left" ever reaches. Anything older is a picture of a
        // window nothing on screen names.
        for (subject, slot) in slots
        where isWindow(subject) && !released.contains(subject) && demands[subject] == nil {
            slot.dropFrame()
        }
    }

    /// Forgets a window completely: its demand, its slot, and — the part that
    /// actually matters — the last frame captured from it.
    ///
    /// Releasing the frame is the point. `SLSHWCaptureWindowList` hands back the
    /// window's own backing store rather than a copy of it, so holding that
    /// image holds the surface, and the window server keeps a window alive for
    /// as long as anything holds its surface. A closed window whose last frame
    /// is still in a slot therefore goes on being listed by
    /// `CGWindowListCopyWindowInfo` indefinitely — measured: 0.2s to disappear
    /// when nothing holds a frame, never when something does — which made a
    /// closed window look, to everything downstream, exactly like a minimized
    /// one that was still there.
    ///
    /// Called when a window is known to be gone, not when a thumbnail merely
    /// stops being shown: `clearWindowDemands` deliberately keeps slots and
    /// their frames so that a rebuilt panel draws complete rather than filling
    /// in a frame at a time.
    func forgetWindow(_ id: CGWindowID) {
        let subject = Subject.window(id)
        demands.removeValue(forKey: subject)
        guard let slot = slots.removeValue(forKey: subject) else { return }
        slot.isLive = false
        // Nilled on the slot itself and not merely dropped from the table,
        // because a thumbnail still on screen holds its own reference to the
        // slot and would keep the surface alive through it.
        slot.image = nil
    }

    /// The windows the engine is following right now.
    ///
    /// For the self test, and it checks the one thing about liveness that frames
    /// cannot: a window whose content happens to be static produces no new
    /// frames whether it is subscribed or not, so "the panel is on the feed" has
    /// to be asked directly rather than inferred from pictures arriving.
    var followedWindows: Set<CGWindowID> {
        Set(demands.keys.compactMap { subject in
            if case .window(let id) = subject { return id }
            return nil
        })
    }

    private func isWindow(_ subject: Subject) -> Bool {
        if case .window = subject { return true }
        return false
    }

    // MARK: - The tick

    private func fire() {
        guard isEnabled else { stop(); return }

        // Never let a slow tick pile work onto the next one. The window server
        // serialises captures anyway, so a backlog would only add latency.
        //
        // The deadline is the safety net: each capture is individually bounded,
        // so a batch cannot legitimately outlive this. If one somehow does, the
        // flag is cleared rather than left to wedge the engine for the session.
        if isCapturing {
            guard Date().timeIntervalSince(captureStartedAt) > captureWatchdog else { return }
            isCapturing = false
        }

        tick &+= 1
        expireStaleSlots()
        refreshWindowMapIfNeeded()
        capture(scheduledSubjects(), tracksBudget: true)
    }

    /// Captures a set of subjects once, immediately, outside the tick budget.
    ///
    /// For the moment a surface appears with nothing to show yet. The first tick
    /// is up to a sixteenth of a second away and would only cover
    /// `maximumPerTick` of them, so a six-window Dock preview would visibly fill
    /// in a pair at a time. A preview that arrives complete reads as faster than
    /// one that assembles itself, and this happens once per appearance rather
    /// than per tick.
    ///
    /// The window map is rebuilt rather than reused: the caller has just
    /// enumerated windows of its own to decide what to ask for, and a map up to
    /// a second old may not have the window it means.
    func prime(_ subjects: [Subject]) {
        guard isEnabled, !subjects.isEmpty else { return }
        refreshWindowMap()
        // A newer panel supersedes an older one outright: whatever the last one
        // was still priming is for windows nobody is looking at now.
        primeBatch?.cancel()
        primeBatch = capture(subjects, tracksBudget: false)
    }

    /// Calls off whatever is still being primed, for a surface that has gone.
    ///
    /// The frames would be dropped on arrival anyway — `deliver` refuses a frame
    /// nothing is following — but not before the window server had been asked for
    /// every one of them, ahead of anything the user can actually see.
    func cancelPriming() {
        primeBatch?.cancel()
        primeBatch = nil
    }

    /// - Parameter tracksBudget: whether this batch owns the "a capture is in
    ///   flight" flag. A priming batch deliberately does not, so it can run
    ///   alongside a tick that is already under way — they serialise on the
    ///   capture queue regardless, and each call is individually bounded.
    @discardableResult
    private func capture(_ subjects: [Subject], tracksBudget: Bool) -> CaptureBatch? {
        // Resolved on the main actor so the background queue never touches
        // engine state. The source width travels with the work because it is
        // what turns a pixel count back into a point size, and the map it comes
        // from may have been rebuilt by the time the frame lands.
        let work: [(subject: Subject, window: CGWindowID, width: CGFloat, onScreen: Bool)] =
            subjects.compactMap { subject in
                guard let reference = self.reference(for: subject) else { return nil }
                return (subject, reference.id, reference.bounds.width, reference.isOnScreen)
            }
        guard !work.isEmpty else { return nil }

        // Stamped where the work is committed to rather than where a frame comes
        // back, because this is what the scheduler's rotation is measured by and
        // a capture that returns nothing new still consumed a slot in the budget.
        let attemptedAt = Date()
        for item in work { slots[item.subject]?.lastAttempt = attemptedAt }

        let known = work.reduce(into: [Subject: UInt64]()) { result, item in
            result[item.subject] = slots[item.subject]?.frameHash ?? 0
        }

        if tracksBudget {
            isCapturing = true
            captureStartedAt = Date()
        }
        let batch = CaptureBatch()
        queue.async {
            var delivered: [(Subject, CGImage, UInt64, CGFloat, Bool)] = []
            // Every attempt is reported back, not just the ones that produced a
            // frame worth publishing: whether the capture *returned* anything is
            // the only thing that separates a window with nothing new to say
            // from a capture path that has stopped working.
            var succeeded: [Subject] = []
            var failed: [Subject] = []

            for item in work {
                // Checked between captures rather than only before the batch:
                // six of them at ~10.5ms each is half a second, and the whole
                // point of cancelling is not to spend it.
                guard !batch.isCancelled else { break }
                guard let image = WindowServerCapture.image(ofWindow: item.window) else {
                    failed.append(item.subject)
                    continue
                }
                succeeded.append(item.subject)
                let sample = FrameSample.of(image)
                // A flat, empty frame means the window has not drawn yet.
                // Publishing it would replace a perfectly good remembered still
                // with a blank rectangle, so it is dropped and the still stands.
                guard !sample.isBlank else { continue }
                // Unchanged frames are dropped here too, on the background queue,
                // so an idle window never reaches SwiftUI at all.
                guard sample.hash != known[item.subject] else { continue }
                delivered.append((item.subject, image, sample.hash, item.width, item.onScreen))
            }

            Task { @MainActor in
                LiveWindowPreview.shared.deliver(
                    delivered, succeeded: succeeded, failed: failed,
                    clearingBudget: tracksBudget
                )
            }
        }
        return batch
    }

    /// Which subjects are due a capture on this tick.
    ///
    /// Focused subjects go every tick; visible ones share a slower cadence. The
    /// result is truncated to `maximumPerTick` with focused ones first, so under
    /// pressure it is always the thing being looked at that keeps moving.
    ///
    /// The two surfaces are gated separately here rather than at their call
    /// sites. Both can be switched off independently, and a subscription left
    /// behind by a surface the user has since disabled must cost nothing —
    /// filtering at the point the budget is spent is the one place that is
    /// guaranteed to be true.
    private func scheduledSubjects() -> [Subject] {
        let prefs = Preferences.shared
        let isSlowTick = tick % visibleDivisor != 0

        return demands
            .filter { subject, demand in
                let wanted: Bool
                switch subject {
                case .application: wanted = prefs.livePreviews
                case .window: wanted = prefs.dockPreviews
                }
                return wanted && (demand == .focused || !isSlowTick)
            }
            .sorted { lhs, rhs in
                // Demand first, then staleness. The tiebreak is not cosmetic:
                // with more equally-demanding subjects than a tick can afford —
                // six windows of one app in a Dock preview, a long rail — a
                // stable sort would hand the budget to the same subset on every
                // tick and the rest would never refresh at all.
                //
                // Staleness is measured from the last capture *attempted*, not
                // the last frame that arrived, and the difference is the whole
                // fairness of this. An unchanged frame is dropped on the capture
                // queue and never becomes an arrival, so a window whose content
                // is static — an idle terminal, a document nobody is typing in —
                // has no arrivals to be stale by. Every such subject then ties at
                // `.distantPast` forever, the sort falls back to whatever order
                // the dictionary hands over, and it is the same order every tick:
                // measured, six windows of Terminal in a Dock preview left two of
                // them with zero captures in four seconds, permanently frozen on
                // their priming frame. Attempts always advance, so this rotates.
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lastAttempt(of: lhs.key) < lastAttempt(of: rhs.key)
            }
            .prefix(maximumPerTick)
            .map(\.key)
    }

    private func lastAttempt(of subject: Subject) -> Date {
        slots[subject]?.lastAttempt ?? .distantPast
    }

    private func reference(for subject: Subject) -> WindowServerCapture.WindowRef? {
        switch subject {
        case .application(let bundleID): return windowForBundle[bundleID]
        case .window(let id): return windowByID[id]
        }
    }

    private func deliver(
        _ frames: [(Subject, CGImage, UInt64, CGFloat, Bool)],
        succeeded: [Subject], failed: [Subject], clearingBudget: Bool
    ) {
        if clearingBudget { isCapturing = false }
        let now = Date()

        for subject in succeeded {
            slots[subject]?.consecutiveFailures = 0
        }
        for subject in failed {
            guard let slot = slots[subject] else { continue }
            slot.consecutiveFailures += 1
            // Screen Recording revoked mid-session, or `replayd` wedged: the
            // preview is showing a frozen frame, so it must stop calling it live.
            if slot.consecutiveFailures >= Self.failureTolerance {
                slot.isLive = false
            }
        }

        for (subject, image, frameHash, sourceWidth, isOnScreen) in frames {
            // Nobody is following this any more, so the frame is dropped rather
            // than filed. Reaching for `slot(for:)` here would *create* the slot,
            // which is the trap: a capture takes up to its own timeout to come
            // back, so a window closed from its Dock thumbnail routinely has one
            // in flight when `forgetWindow` runs. Filing that frame would put the
            // window's backing store straight back into a slot nothing will ever
            // capture for again, which — see `forgetWindow` — is exactly what
            // keeps a closed window listed by the window server forever, and
            // makes the close button appear to do nothing.
            guard demands[subject] != nil else { continue }
            let slot = slot(for: subject)
            slot.frameHash = frameHash
            slot.lastArrival = now
            slot.isOffScreen = !isOnScreen

            // Point size from the real pixel-to-point ratio of this capture, so
            // a preview can apply the same "never enlarge past what was actually
            // captured" rule it applies to every other image — a window dragged
            // onto a non-Retina display really does come back at 1×.
            let scale = sourceWidth > 0
                ? max((CGFloat(image.width) / sourceWidth).rounded(), 1)
                : 2
            slot.image = NSImage(
                cgImage: image,
                size: NSSize(
                    width: CGFloat(image.width) / scale,
                    height: CGFloat(image.height) / scale
                )
            )
            slot.isLive = true

            // Write the occasional live frame through to the on-disk cache, so
            // there is still something recent to show after the app quits — which
            // is exactly what a Dock tile for a closed app falls back to.
            if now.timeIntervalSince(slot.lastPersisted) >= persistInterval {
                slot.lastPersisted = now
                persist(slot.image, for: subject)
            }
        }
    }

    /// Folds a live frame back into the persistent per-application cache.
    ///
    /// Both kinds of subject can feed it, and a window subject is worth
    /// following through: hovering a Dock tile is often the last time a window
    /// is seen before its app is quit, which makes it the freshest still that
    /// tile will ever have to fall back to.
    private func persist(_ image: NSImage?, for subject: Subject) {
        guard let image else { return }

        let reference: WindowServerCapture.WindowRef?
        let bundleID: String?

        switch subject {
        case .application(let identifier):
            reference = windowForBundle[identifier]
            bundleID = identifier
        case .window(let id):
            reference = windowByID[id]
            bundleID = reference
                .flatMap { NSRunningApplication(processIdentifier: $0.pid) }?
                .bundleIdentifier
        }

        guard let bundleID else { return }
        AppWindowCapture.shared.adoptLiveFrame(image, for: bundleID, window: reference)
    }

    /// Drops the "live" claim from any slot that has stopped receiving frames
    /// because nobody is following it any more.
    ///
    /// The other way a slot goes stale — still followed, but the captures have
    /// started failing — is not decidable here, because an absence of frames is
    /// also what a perfectly healthy static window looks like. That case is
    /// handled in `deliver`, by counting failed *attempts*.
    private func expireStaleSlots() {
        let cutoff = Date().addingTimeInterval(-liveTimeout)
        for (subject, slot) in slots where slot.isLive && slot.lastArrival < cutoff {
            // A window whose content is simply static is not stale: it is still
            // being followed, it just has nothing new to say.
            if demands[subject] == nil { slot.isLive = false }
        }
    }

    // MARK: - Window resolution

    private func refreshWindowMapIfNeeded() {
        guard Date().timeIntervalSince(windowMapRefreshedAt) >= windowMapLifetime else { return }
        refreshWindowMap()
    }

    private func refreshWindowMap() {
        windowMapRefreshedAt = Date()

        // One enumeration feeds both maps. The per-window map is every candidate
        // there is, because a Dock thumbnail follows a window the per-application
        // map deliberately discarded — an app's second and third windows are not
        // the one that best represents it, and are exactly what the Dock panel
        // exists to show.
        //
        // Both maps are filtered by the same policy that decides what may be
        // photographed at all, and this is the only place either of them is
        // built — so a window belonging to the authentication agent or a
        // password manager has no reference here, and a subject naming one is
        // simply never captured. That check used to live only on the paths that
        // *store* a frame, which protected the disk cache and nothing else: a
        // deck card for 1Password still put its window on screen live, next to
        // whoever is standing behind the user. Refusing the reference is what
        // makes the rule cover the screen as well as the cache, and it costs one
        // set lookup per window per second.
        // One walk of the process table rather than a lookup per window: a busy
        // desktop has far more windows than applications, and every window
        // needs the same question answered about its owner — and that walk
        // only when the table has changed. See `bundleIDsByPID`.
        let bundleIDs: [pid_t: String]
        if let cached = bundleIDsByPID {
            bundleIDs = cached
        } else {
            var built: [pid_t: String] = [:]
            for app in NSWorkspace.shared.runningApplications {
                guard let bundleID = app.bundleIdentifier else { continue }
                built[app.processIdentifier] = bundleID
            }
            bundleIDsByPID = built
            bundleIDs = built
        }

        let candidates = WindowServerCapture.candidateWindows().filter { window in
            // An unidentified process is kept: it cannot be on the deny list,
            // which is written in bundle identifiers.
            guard let bundleID = bundleIDs[window.pid] else { return true }
            return AppWindowCapture.isCaptureAllowed(bundleID: bundleID)
        }
        windowByID = candidates.reduce(into: [:]) { $0[$1.id] = $1 }

        var byBundle: [String: WindowServerCapture.WindowRef] = [:]
        for (pid, window) in WindowServerCapture.bestWindowPerProcess(from: candidates) {
            guard let bundleID = bundleIDs[pid],
                  bundleID != Bundle.main.bundleIdentifier
            else { continue }
            byBundle[bundleID] = window
        }
        windowForBundle = byBundle

        // Anything whose window is simply gone cannot be live, however recently
        // it was — an app that closed its last window, or a window that was
        // closed while its thumbnail was on screen.
        for (subject, slot) in slots where reference(for: subject) == nil {
            slot.isLive = false
        }
    }
}
