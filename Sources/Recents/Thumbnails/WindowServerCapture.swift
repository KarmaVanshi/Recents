import AppKit
import CoreGraphics

/// Reads the pixels of a window directly from the window server, including
/// windows that are minimized, hidden or buried behind other windows.
///
/// This exists because the public capture APIs cannot do it, which was measured
/// rather than assumed. On macOS 26.5, for a window that is not on screen:
///
///   • `SCScreenshotManager.captureImage` throws "Failed to start stream due to
///     audio/video capture failure".
///   • An `SCStream` built on `SCContentFilter(desktopIndependentWindow:)`
///     starts without error and then delivers **zero** frames, indefinitely.
///
/// So ScreenCaptureKit is not merely slow for an offscreen window; it is blind to
/// it. `SLSHWCaptureWindowList` is not: it returns the window's *current* backing
/// store, and if the owning app is still drawing — a video player decoding into an
/// `AVPlayerLayer`, say — successive calls return successive frames. That is what
/// makes a Windows-style live thumbnail of a minimized window possible at all.
///
/// It is private SkyLight SPI, so every entry point is resolved with `dlsym` at
/// startup and the whole facility reports itself unavailable if any symbol is
/// missing. Callers are expected to fall back to ScreenCaptureKit, and the app is
/// fully functional with this returning nil forever — it only ever *adds* frames
/// that the public API declined to provide.
///
/// Measured cost on an M-series Mac: ~10.5 ms wall per window, of which ~0.2 ms
/// is CPU. The call is almost entirely a blocking round trip to the window
/// server, and it does not parallelise — four concurrent captures take the same
/// wall time as four sequential ones, because the server serialises them. Both
/// facts drive the pacing in `LiveWindowPreview`: run it off the main thread,
/// and budget by *call count*, not by CPU.
enum WindowServerCapture {

    // MARK: - Symbol binding

    private typealias ConnectionID = UInt32
    private typealias MainConnectionFn = @convention(c) () -> ConnectionID
    private typealias CaptureFn = @convention(c) (
        ConnectionID, UnsafePointer<CGWindowID>, UInt32, UInt32
    ) -> Unmanaged<CFArray>?

    /// Do not clip the capture to the visible screen area. Without it a window
    /// that hangs off the edge of a display comes back cropped to the part that
    /// would have been visible — and a minimized window is, in effect, entirely
    /// off the edge.
    private static let ignoreGlobalClipShape: UInt32 = 1 << 11

    private struct Bindings {
        var mainConnection: MainConnectionFn
        var capture: CaptureFn
    }

    private static let bindings: Bindings? = {
        // The modern name is SLS…; the CGS… aliases are the older ones. Trying
        // both means this keeps working across the rename either way.
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
        ) else { return nil }

        func symbol(_ names: String...) -> UnsafeMutableRawPointer? {
            for name in names {
                if let pointer = dlsym(handle, name) { return pointer }
            }
            return nil
        }

        guard let connection = symbol("SLSMainConnectionID", "CGSMainConnectionID"),
              let capture = symbol("SLSHWCaptureWindowList", "CGSHWCaptureWindowList")
        else { return nil }

        return Bindings(
            mainConnection: unsafeBitCast(connection, to: MainConnectionFn.self),
            capture: unsafeBitCast(capture, to: CaptureFn.self)
        )
    }()

    /// Whether this facility can be used at all. False on any OS where the
    /// symbols have been renamed or removed, which is the case the fallbacks
    /// exist for.
    static var isAvailable: Bool { bindings != nil }

    // MARK: - Capturing

    /// The one queue the SPI is ever called on.
    ///
    /// On macOS 26 this call is not the straight window-server round trip its
    /// name suggests. A stack sample taken while it was wedged shows it routed
    /// through ScreenCaptureKit —
    /// `SLSHWCaptureWindowList` → `SLSHWCaptureWindowListToIOSurfaceProxying` →
    /// `dispatch_semaphore_wait` — so it depends on `replayd`, and when that
    /// daemon is saturated (two processes capturing at once will do it) the call
    /// blocks for seconds. Confining it to one private serial queue means a stall
    /// can never reach the main thread, a Swift concurrency worker, or a caller's
    /// queue; it can only make this one thread wait.
    private static let captureQueue = DispatchQueue(
        label: "com.recents.deck.windowserver", qos: .userInitiated
    )

    /// Set while a call is in flight, so a request that has been sitting behind a
    /// wedged one can be dropped instead of executed long after anybody wanted it.
    private final class Request {
        let deadline: DispatchTime
        var image: CGImage?
        init(deadline: DispatchTime) { self.deadline = deadline }
    }

    /// The current pixels of one window, on screen or not.
    ///
    /// Blocks the calling thread for at most `timeout`. On expiry it returns nil
    /// and the caller carries on; the underlying call is left to finish on the
    /// private queue, and anything queued behind it that has already expired is
    /// discarded rather than run, so the backlog drains instantly once the stall
    /// clears.
    ///
    /// Never call this from the main thread — there is a deliberate guard, since
    /// a multi-second freeze of the deck is far worse than a missing frame. Pass
    /// exactly one window id: handing the list more than one makes the server
    /// return a *single* image of their combined bounds rather than one image
    /// each, which is not what any caller here wants.
    static func image(
        ofWindow windowID: CGWindowID, timeout: TimeInterval = 0.3
    ) -> CGImage? {
        guard bindings != nil else { return nil }
        assert(!Thread.isMainThread, "WindowServerCapture blocks; keep it off the main thread")
        guard !Thread.isMainThread else { return nil }

        let request = Request(deadline: .now() + timeout)
        let finished = DispatchSemaphore(value: 0)

        captureQueue.async {
            // Whoever asked for this has already given up, so do not spend a
            // window-server round trip on it.
            guard request.deadline > .now() else { finished.signal(); return }
            request.image = capture(windowID)
            finished.signal()
        }

        guard finished.wait(timeout: request.deadline) == .success else { return nil }
        return request.image
    }

    /// The async form, for callers on a Swift concurrency executor. Blocking a
    /// cooperative thread starves the whole pool, so those callers must use this
    /// rather than the synchronous version. Distinctly named because an
    /// overload that differs only in `async` is far too easy to call the wrong
    /// one of by forgetting an `await`.
    ///
    /// Bounded by the same deadline as the synchronous version, and for the same
    /// reason. This used to await the queue with no timeout at all, which made
    /// it the one path in the file that could hang forever: on macOS 26 the call
    /// routes through `replayd` (see the note on `captureQueue`), and a
    /// saturated daemon blocks it for seconds. `AppWindowCapture` marks an app
    /// as having a capture in flight before awaiting this, so a call that never
    /// returned took that app's thumbnail out for the rest of the session.
    ///
    /// On expiry the caller is given nil and the underlying call is left to
    /// finish on the private queue, exactly as in the synchronous path — and
    /// anything queued behind it that has already expired is skipped rather than
    /// run, so the backlog drains as soon as the stall clears.
    static func imageAsync(
        ofWindow windowID: CGWindowID, timeout: TimeInterval = 0.3
    ) async -> CGImage? {
        guard bindings != nil else { return nil }

        let deadline = DispatchTime.now() + timeout
        let once = SingleResume()

        return await withCheckedContinuation { continuation in
            once.arm(continuation)

            captureQueue.async {
                // Whoever asked for this has already given up, so do not spend a
                // window-server round trip on it.
                guard deadline > .now() else { once.resume(nil); return }
                once.resume(capture(windowID))
            }

            // Deliberately not on `captureQueue`: the whole point is to fire
            // while that queue is the thing that is stuck.
            timeoutQueue.asyncAfter(deadline: deadline) { once.resume(nil) }
        }
    }

    /// Timers only. Kept off `captureQueue` so a wedged capture cannot delay the
    /// deadline that is supposed to rescue the caller from it.
    private static let timeoutQueue = DispatchQueue(
        label: "com.recents.deck.windowserver.timeout", qos: .userInitiated
    )

    /// Resumes a continuation exactly once, whichever of the capture and the
    /// timeout gets there first. Resuming a `CheckedContinuation` twice is a
    /// hard crash, and both callers race by construction.
    private final class SingleResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CGImage?, Never>?
        private var isResumed = false

        func arm(_ continuation: CheckedContinuation<CGImage?, Never>) {
            lock.lock()
            defer { lock.unlock() }
            self.continuation = continuation
        }

        func resume(_ image: CGImage?) {
            lock.lock()
            let pending = isResumed ? nil : continuation
            isResumed = true
            continuation = nil
            lock.unlock()
            pending?.resume(returning: image)
        }
    }

    /// The raw call. Only ever reached from `captureQueue`.
    private static func capture(_ windowID: CGWindowID) -> CGImage? {
        guard let bindings else { return nil }
        var list = [windowID]
        guard let array = bindings.capture(
            bindings.mainConnection(), &list, 1, ignoreGlobalClipShape
        )?.takeRetainedValue() as? [CGImage] else { return nil }
        return array.first
    }

    // MARK: - Finding windows

    /// One candidate window belonging to some application.
    struct WindowRef {
        var id: CGWindowID
        var pid: pid_t
        /// Point size, as the window server reports it.
        var bounds: CGRect
        var title: String?
        /// False for a minimized window, a hidden app's window, and a window on
        /// another Space.
        var isOnScreen: Bool
    }

    /// Every real document window on the system, whether or not it is on screen.
    ///
    /// `.optionAll` rather than `.optionOnScreenOnly` is the whole point: the
    /// on-screen list cannot see a minimized window, so neither could anything
    /// built on it. Palettes, panels and the menu bar are filtered out here for
    /// the same reason `AppWindowCapture` filters them — a 40×22 toolbar makes a
    /// useless thumbnail.
    ///
    /// The subtle filter is the one on untitled offscreen windows. macOS keeps a
    /// 500×500 untitled placeholder window offscreen for a great many processes —
    /// Finder, Safari, Messages and every open/save panel service all have one —
    /// and it captures as a blank rectangle. An app whose only window was one of
    /// those would show a live preview of nothing, which is strictly worse than
    /// the remembered still it would have replaced. A genuinely minimized
    /// document window always carries the title macOS shows in its Dock tile, so
    /// requiring one separates the two cases exactly.
    static func candidateWindows() -> [WindowRef] {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return raw.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let rect = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: rect as CFDictionary),
                  bounds.width >= 200, bounds.height >= 150,
                  // A fully transparent window has nothing to show either.
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01
            else { return nil }

            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let title = entry[kCGWindowName as String] as? String
            let hasTitle = !(title ?? "").isEmpty

            // On screen is self-evidently real; offscreen has to prove it.
            guard isOnScreen || hasTitle else { return nil }

            return WindowRef(
                id: id, pid: pid, bounds: bounds, title: title, isOnScreen: isOnScreen
            )
        }
    }

    /// The one window that best represents each process.
    ///
    /// An on-screen window always beats an offscreen one — if the user can see a
    /// window right now, that is the one whose contents they mean — and within a
    /// group, the largest wins, which is almost always the document window rather
    /// than a find bar or an inspector.
    static func bestWindowPerProcess(from windows: [WindowRef]) -> [pid_t: WindowRef] {
        var best: [pid_t: WindowRef] = [:]
        for window in windows {
            guard let existing = best[window.pid] else {
                best[window.pid] = window
                continue
            }
            if isBetter(window, than: existing) { best[window.pid] = window }
        }
        return best
    }

    private static func isBetter(_ lhs: WindowRef, than rhs: WindowRef) -> Bool {
        if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
        return lhs.bounds.width * lhs.bounds.height > rhs.bounds.width * rhs.bounds.height
    }
}

// MARK: - Fingerprinting

/// A cheap read of what a captured frame contains.
///
/// Two questions get answered from one pass over ~512 sampled bytes: has this
/// frame changed since the last one, and is there anything in it at all.
///
/// The first keeps an idle window from costing a redraw. A window sitting still
/// still costs a capture — there is no way to ask the server "has this changed?"
/// — but it should not cost SwiftUI anything, and sampling plus hashing takes
/// about a microsecond against ~10.5 ms for the capture itself.
///
/// The second is a guard against replacing a good remembered still with a blank
/// rectangle. A window that has been asked for its pixels before it has drawn
/// any comes back a single flat colour, and showing that as a "live" preview
/// would be a straight downgrade.
///
/// Both are sampling measures, so a change confined to pixels that were not
/// looked at can be missed. That is an acceptable trade for a preview: the worst
/// case is one stale thumbnail frame, and the next real change lands.
struct FrameSample {

    let hash: UInt64
    /// True when every sampled byte is near-identical — a flat, empty frame.
    let isBlank: Bool

    static func of(_ image: CGImage) -> FrameSample {
        guard let data = image.dataProvider?.data as Data?, !data.isEmpty else {
            return FrameSample(hash: 0, isBlank: true)
        }

        var hash: UInt64 = 1469598103934665603  // FNV-1a offset basis
        var minimum: UInt8 = .max
        var maximum: UInt8 = .min

        let step = max(1, data.count / 512)
        var index = 0
        while index < data.count {
            let byte = data[index]
            hash = (hash ^ UInt64(byte)) &* 1099511628211
            if byte < minimum { minimum = byte }
            if byte > maximum { maximum = byte }
            index += step
        }

        // Fold in the dimensions so a resize is never mistaken for no change.
        hash = (hash ^ UInt64(UInt32(truncatingIfNeeded: image.width))) &* 1099511628211
        hash = (hash ^ UInt64(UInt32(truncatingIfNeeded: image.height))) &* 1099511628211

        return FrameSample(hash: hash, isBlank: maximum &- minimum < 8)
    }
}
