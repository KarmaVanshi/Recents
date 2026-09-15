import AppKit
import OSLog

/// Watches the trackpad for a gesture the system has not already claimed.
///
/// Every gesture AppKit will tell an app about is spoken for: pinch zooms the
/// frontmost app, a three-finger swipe pages through it, and four- and
/// five-finger gestures are consumed by the window server for Mission Control
/// and Launchpad before any application sees them. `NSEvent`'s global monitors
/// can therefore only observe gestures that are *also* doing something else,
/// which is no use for summoning a window.
///
/// `MultitouchSupport` is the layer underneath all of that — the raw contacts
/// the trackpad reports, before the window server decides what they mean. It is
/// what every third-party gesture utility uses, and it is the only way to bind
/// something like a four-finger *tap*, which no system gesture uses.
///
/// It is private SPI, so it follows the same discipline as `WindowServerCapture`:
/// every entry point is resolved with `dlsym`, the whole facility reports itself
/// unavailable if anything is missing, and the app is fully functional with this
/// switched off forever. The hotkey and the menu bar item remain the summoning
/// routes that cannot break.
enum MultitouchSupport {

    // MARK: - Contact records
    //
    // The contact struct is undocumented. Rather than mirror the whole thing in
    // Swift — which would also mean trusting Swift to lay its fields out exactly
    // as C does, something the language does not promise — this reads the two
    // floats it actually needs at their known byte offsets, and range-checks
    // them before believing either. Being wrong about a layout means reading
    // plausible-looking garbage rather than crashing, which is the dangerous
    // kind of wrong, so the check is the point.

    struct Point { var x: Float = 0; var y: Float = 0 }

    enum Contact {
        /// sizeof(MTTouch), on the layout every open-source consumer of this
        /// framework has converged on:
        ///
        ///     int32 frame; (pad); double timestamp; int32 identifier, state,
        ///     fingerID, handID; float normalized[4]; float size; int32 pressure;
        ///     float angle, majorAxis, minorAxis; float absolute[4];
        ///     int32 reserved[2]; float density;
        ///
        /// — 92 bytes, rounded to 96 by the double's alignment.
        static let stride = 96

        /// Offset of `normalized.position`, two floats in 0…1 giving the finger's
        /// place on the trackpad surface. The only field this file depends on.
        static let normalizedPositionOffset = 32
    }

    typealias DeviceRef = UnsafeMutableRawPointer
    /// The touches argument is `MTTouch *`; it stays a raw pointer because a
    /// `@convention(c)` signature may only mention C-representable types.
    typealias ContactCallback = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
    ) -> Int32

    // MARK: - Symbol binding

    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias RegisterFn = @convention(c) (DeviceRef, ContactCallback) -> Void
    private typealias UnregisterFn = @convention(c) (DeviceRef, ContactCallback) -> Void
    private typealias StartFn = @convention(c) (DeviceRef, Int32) -> Void
    private typealias StopFn = @convention(c) (DeviceRef) -> Void
    private typealias IsBuiltInFn = @convention(c) (DeviceRef) -> Bool

    private struct Bindings {
        var createList: CreateListFn
        var register: RegisterFn
        var unregister: UnregisterFn
        var start: StartFn
        var stop: StopFn
        var isBuiltIn: IsBuiltInFn?
    }

    private static let bindings: Bindings? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        ) else { return nil }

        func symbol(_ name: String) -> UnsafeMutableRawPointer? { dlsym(handle, name) }

        guard let createList = symbol("MTDeviceCreateList"),
              let register = symbol("MTRegisterContactFrameCallback"),
              let unregister = symbol("MTUnregisterContactFrameCallback"),
              let start = symbol("MTDeviceStart"),
              let stop = symbol("MTDeviceStop")
        else { return nil }

        return Bindings(
            createList: unsafeBitCast(createList, to: CreateListFn.self),
            register: unsafeBitCast(register, to: RegisterFn.self),
            unregister: unsafeBitCast(unregister, to: UnregisterFn.self),
            start: unsafeBitCast(start, to: StartFn.self),
            stop: unsafeBitCast(stop, to: StopFn.self),
            // Only used to label devices in the self-test, so its absence is not
            // a reason to disable the facility.
            isBuiltIn: symbol("MTDeviceIsBuiltIn").map {
                unsafeBitCast($0, to: IsBuiltInFn.self)
            }
        )
    }()

    /// Whether the framework and every symbol this file needs are present.
    /// Whether this Mac has a trackpad the app can actually read.
    ///
    /// The framework loading is not the question. `MultitouchSupport.framework`
    /// is present on every Mac, desktops included, so `bindings != nil` answered
    /// yes on hardware with no trackpad at all — and everything downstream
    /// believed it. Settings offered the gesture with its switch live and its
    /// shape dropdown showing; the status menu reported the chosen shape; and no
    /// contact ever arrived, because there was no device to deliver one. The
    /// "no trackpad the app can read" subtitle written for exactly this case
    /// could never appear, because the condition it hangs on was never false.
    ///
    /// Asked fresh rather than resolved once: a Magic Trackpad can be paired
    /// while the app is running, and both callers — the Settings body and the
    /// status menu — are cold enough to afford the framework call.
    static var isAvailable: Bool { bindings != nil && !deviceList().devices.isEmpty }

    /// The devices, together with the array that owns them.
    ///
    /// Both halves matter, and getting it wrong fails silently. The handles are
    /// *borrowed* from the CFArray rather than retained individually, so if the
    /// array is released the devices go with it — and a released device does not
    /// complain. `MTDeviceStart` still returns, `MTDeviceIsRunning` still says
    /// true, and the contact callback simply never fires. That is exactly what
    /// happened when this returned a bare `[DeviceRef]` and let the array fall
    /// out of scope: a facility that looked started and delivered nothing. Hold
    /// the list for as long as the devices are in use.
    struct DeviceList {
        fileprivate let owner: CFArray
        let devices: [DeviceRef]

        static let empty = DeviceList(owner: [] as CFArray, devices: [])
    }

    static func deviceList() -> DeviceList {
        guard let bindings, let list = bindings.createList()?.takeRetainedValue()
        else { return .empty }
        // Read the pointers straight out of the CFArray rather than bridging it
        // to NSArray first: the elements are opaque `MTDevice` handles, and
        // bridging hands back boxed objects whose addresses are not the handles
        // the framework expects back.
        let devices = (0..<CFArrayGetCount(list)).compactMap { index in
            UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, index))
        }
        return DeviceList(owner: list, devices: devices)
    }

    static func isBuiltIn(_ device: DeviceRef) -> Bool {
        bindings?.isBuiltIn?(device) ?? false
    }

    static func register(_ device: DeviceRef, _ callback: ContactCallback) {
        bindings?.register(device, callback)
    }

    static func unregister(_ device: DeviceRef, _ callback: ContactCallback) {
        bindings?.unregister(device, callback)
    }

    static func start(_ device: DeviceRef) { bindings?.start(device, 0) }
    static func stop(_ device: DeviceRef) { bindings?.stop(device) }
}

/// One frame of trackpad contacts, reduced to what a gesture needs.
struct TouchFrame {
    var fingerCount: Int
    var timestamp: Double
    /// Empty when the contact layout failed validation — see `Touch`.
    var positions: [MultitouchSupport.Point]
    /// Whether a mouse button was physically down when this frame was reported.
    ///
    /// Sampled per frame rather than observed as an event, because it has to be
    /// answered on the contact thread and cannot wait on the main one — see
    /// `TrackpadGestureWatcher.handle`. Defaulted, so the self-test and the
    /// recogniser's own tests can build a frame without it.
    var isClicking: Bool = false
    /// Whether the system was delivering a finger-driven scroll around the time
    /// this frame was reported.
    ///
    /// The one thing that separates a two-finger tap from the gesture two
    /// fingers actually mean. See `TapRecognizer`.
    var isScrolling: Bool = false
}

/// Recognises "N fingers tapped, together, without travelling".
///
/// A tap rather than a swipe deliberately: a four-finger *swipe* is Mission
/// Control and App Exposé, and a gesture that fires on the way into those would
/// be worse than no gesture at all. A flat tap is not bound to anything, which
/// is what makes it available.
///
/// The rules are all about telling a tap apart from the start of a swipe:
///
///   • the peak finger count must be exactly `fingerCount` — five fingers
///     landing means the user reached for Launchpad, not for this;
///   • all of them must land close together in time, so resting a hand on the
///     trackpad and then adding a finger never counts;
///   • every finger must lift within `maxDuration`, because a swipe holds
///     contact while it travels;
///   • no finger may travel more than `maxTravel` of the trackpad's width; and
///   • no mouse button may go down while they are on the trackpad; and
///   • the system may not be scrolling while they are on it.
///
/// The travel test is the one that needs the contact layout to be right. Without
/// it the other three still hold, and they are what does most of the work.
///
/// The click test is what makes a two-finger shape usable at all. A physical
/// two-finger *click* is the secondary click on a stock Mac, and from the
/// contacts alone it is indistinguishable from a two-finger tap: two fingers
/// land, stay put, and lift. Without this, binding two fingers would summon the
/// deck on every right click. Reading the button state instead of the contacts
/// separates them exactly — a tap is a touch with no press in it — and the rule
/// is applied at every finger count rather than only at two, because "clicking
/// with three fingers down" was never meant to be this gesture either.
///
/// The scroll test is the other half of the same problem, and it is the one that
/// was learned the expensive way. Two fingers on a trackpad are, overwhelmingly,
/// a *scroll*, and the travel test does not catch a short one: a few lines of
/// scrolling moves the centroid well under `maxTravel`. Bound to two fingers
/// without this, the gesture fired every 0.2 to 0.9 seconds through ordinary
/// reading — each fire toggling the deck, stealing activation, and tearing down
/// whatever menu happened to be open. A scroll announces itself as scroll events
/// long before the fingers lift, so an episode with one in it is a scroll and
/// never a tap, whatever the contacts looked like.
struct TapRecognizer {

    var fingerCount: Int
    /// How many taps in a row the gesture asks for.
    ///
    /// Two of them is a shape the system claims at no finger count above two,
    /// and it costs a false fire almost nothing: the first tap alone does not
    /// summon anything, so resting three fingers down once is inert. What it
    /// costs instead is deliberateness — a double tap has to be aimed — which
    /// is the trade the dropdown exists to let someone make.
    var tapCount: Int
    /// Measured, not guessed, and twice too tight before it was.
    ///
    /// A three-finger tap that *feels* instant is not: fingers land and lift
    /// staggered, and observed taps ran 0.78s to 1.61s from first contact to
    /// full release. 0.35s rejected every one of them; 0.9s sat in the middle of
    /// the distribution and threw out half — the worst place a threshold can be.
    ///
    /// It can afford to be this generous because duration is not what separates
    /// a tap from a swipe. `maxTravel` is. This only has to exclude resting a
    /// hand on the trackpad and dragging with it, and those run longer still —
    /// swipe episodes in the same trials lasted 2.0 to 3.7 seconds.
    var maxDuration: Double = 1.8
    var maxLandingSpread: Double = 0.12
    var maxTravel: Float = 0.06
    /// The pause allowed between one tap lifting and the next landing.
    ///
    /// Measured from *lift to land*, not release to release: a single tap here
    /// runs up to `maxDuration`, so a release-to-release window would have to be
    /// nearly two seconds wide to admit an ordinary double tap, and would then
    /// happily weld two unrelated taps together. This is the actual pause, and
    /// it can stay short.
    var maxTapGap: Double = 0.7

    private var isTracking = false
    private var landedAt: Double = 0
    private var lastRiseAt: Double = 0
    private var peak = 0
    private var origins: [MultitouchSupport.Point] = []
    private var travelled: Float = 0
    private var previous = 0
    private var completedTaps = 0
    private var lastTapEndedAt: Double = 0
    /// Whether a mouse button went down at any point in the current episode.
    private var wasClicked = false
    /// Whether the system scrolled at any point in the current episode.
    private var wasScrolled = false

    init(fingerCount: Int = 3, tapCount: Int = 1) {
        self.fingerCount = fingerCount
        self.tapCount = max(1, tapCount)
    }

    /// What one frame did to the recogniser.
    enum Outcome {
        case pending
        case recognised
        /// A clean tap landed, but the gesture asks for more of them. Logged
        /// like the rest: a double tap whose second half keeps arriving too
        /// late is otherwise indistinguishable from a trackpad nobody is
        /// reading.
        case partial(Int, of: Int)
        /// Why an otherwise complete episode was thrown out. Logged, because
        /// a rejected tap and an unread trackpad look identical from outside.
        case rejected(String)
    }

    /// Feeds one frame in and reports what it completed, if anything.
    mutating func accept(_ frame: TouchFrame) -> Outcome {
        defer { previous = frame.fingerCount }

        // Fingers going down.
        if frame.fingerCount > previous {
            if previous == 0 {
                isTracking = true
                landedAt = frame.timestamp
                peak = 0
                origins = []
                travelled = 0
                wasClicked = false
                wasScrolled = false
            }
            lastRiseAt = frame.timestamp
        }

        guard isTracking else { return .pending }

        // Sticky for the whole episode: the press and the release both happen
        // while the fingers are down, so a frame-by-frame answer would go back
        // to false before they lift.
        if frame.isClicking { wasClicked = true }
        if frame.isScrolling { wasScrolled = true }

        peak = max(peak, frame.fingerCount)

        if frame.fingerCount == fingerCount, origins.isEmpty {
            origins = frame.positions
        } else if frame.fingerCount == fingerCount, origins.count == frame.positions.count {
            // Fingers are not reported in a stable order, so compare the spread
            // of the whole group rather than pairing them up: a swipe moves the
            // centroid, and that is what this measures.
            travelled = max(travelled, Self.centroidDistance(origins, frame.positions))
        }

        // Everything lifted — decide.
        guard frame.fingerCount == 0 else { return .pending }
        isTracking = false

        let heldFor = frame.timestamp - landedAt
        let spread = lastRiseAt - landedAt

        // Not a rejection worth reporting: every ordinary click and scroll ends
        // here, and logging them buries the near-misses that are worth seeing.
        guard peak == fingerCount else { return .pending }
        // Before the measurements, because neither of these is a near miss: the
        // user clicked, or the user scrolled, and on two fingers those are what
        // two fingers ordinarily mean.
        if wasClicked { return .pending }
        if wasScrolled { return .pending }
        if heldFor > maxDuration {
            return .rejected(String(format: "held %.2fs, limit %.2fs", heldFor, maxDuration))
        }
        if spread > maxLandingSpread {
            return .rejected(String(format: "landed over %.2fs, limit %.2fs", spread, maxLandingSpread))
        }
        if travelled > maxTravel {
            return .rejected(String(format: "travelled %.3f, limit %.3f", travelled, maxTravel))
        }
        return completeTap(landedAt: landedAt, liftedAt: frame.timestamp)
    }

    /// Books one clean tap and says whether it finished the gesture.
    private mutating func completeTap(landedAt: Double, liftedAt: Double) -> Outcome {
        defer { lastTapEndedAt = liftedAt }
        guard tapCount > 1 else { return .recognised }

        // A tap that comes too late is not a failed double tap; it is the first
        // tap of the next attempt, which is exactly what someone tapping again
        // after a miss means by it.
        if completedTaps > 0, landedAt - lastTapEndedAt <= maxTapGap {
            completedTaps += 1
        } else {
            completedTaps = 1
        }

        guard completedTaps >= tapCount else {
            return .partial(completedTaps, of: tapCount)
        }
        completedTaps = 0
        return .recognised
    }

    private static func centroidDistance(
        _ a: [MultitouchSupport.Point], _ b: [MultitouchSupport.Point]
    ) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        let count = Float(a.count)
        let ax = a.reduce(0) { $0 + $1.x } / count, ay = a.reduce(0) { $0 + $1.y } / count
        let bx = b.reduce(0) { $0 + $1.x } / count, by = b.reduce(0) { $0 + $1.y } / count
        return ((ax - bx) * (ax - bx) + (ay - by) * (ay - by)).squareRoot()
    }
}

/// The trackpad shapes the summon can be bound to, and what each one costs.
///
/// Every one of them is a tap, for the reason the recogniser is built around: a
/// *swipe* at every finger count already means something — pages, spaces,
/// Mission Control, App Exposé — and a summon that fired on the way into one of
/// those would be worse than no summon at all. A flat tap travels nowhere, so it
/// collides with nothing that does.
///
/// Two fingers are the shape that needs the most care, and they used to be left
/// out of this list altogether for it. Three things claim two fingers on a stock
/// Mac: the secondary *click* (`TrackpadRightClick`, on by default), the
/// secondary *tap* when tap-to-click is switched on (`Clicking`), and smart zoom
/// on a two-finger *double* tap (`TrackpadTwoFingerDoubleTapGesture`).
///
/// A single two-finger tap avoids the third outright, and `TapRecognizer` now
/// tells a tap apart from a click by reading the button state — see the note
/// there — which is what takes the first out of the way. That leaves the second,
/// which is a setting rather than a fact: with tap-to-click off, which is how
/// macOS ships, a two-finger tap is genuinely unbound. `systemConflict` says so
/// when it is not.
///
/// A two-finger *double* tap is still absent, and that one is not recoverable:
/// smart zoom is on by default and is the same shape exactly.
enum SummonGesture: String, CaseIterable, Identifiable, Sendable {
    case twoFingerTap
    case threeFingerTap
    case fourFingerTap
    case fiveFingerTap
    case threeFingerDoubleTap
    case fourFingerDoubleTap

    /// Two fingers, tapped once: the shortest reach on the trackpad, and free of
    /// every system gesture once a tap is told apart from a click — which is what
    /// `TapRecognizer` now does, and what this could not be the default without.
    ///
    /// Three fingers held this place before, on measurement rather than taste: in
    /// a 2629-frame trial a three-finger tap recognised eight deliberate taps and
    /// fired zero times across roughly forty three-finger swipes. It is still the
    /// shape to move to if two ever proves too easy to fire by accident, and it
    /// is one line away in Settings.
    static let `default` = SummonGesture.twoFingerTap

    var id: String { rawValue }

    var fingerCount: Int {
        switch self {
        case .twoFingerTap: 2
        case .threeFingerTap, .threeFingerDoubleTap: 3
        case .fourFingerTap, .fourFingerDoubleTap: 4
        case .fiveFingerTap: 5
        }
    }

    var tapCount: Int {
        switch self {
        case .threeFingerDoubleTap, .fourFingerDoubleTap: 2
        default: 1
        }
    }

    /// The name, derived from the counts rather than written out beside them.
    /// The two drifting apart is not hypothetical: the first version of this
    /// feature bound four fingers while Settings advertised three, so it was
    /// unreachable in exactly the way that looks like it is broken.
    var title: String {
        let words = [2: "Two", 3: "Three", 4: "Four", 5: "Five"]
        let count = words[fingerCount] ?? String(fingerCount)
        return "\(count)-finger \(tapCount > 1 ? "double tap" : "tap")"
    }

    /// One line on what this shape is like to live with.
    var summary: String {
        switch self {
        case .twoFingerTap:
            return "The quickest shape there is, and a tap rather than a click — "
                 + "clicking with two fingers stays the secondary click and never "
                 + "summons this. It needs “Tap to click” left off, which is how "
                 + "macOS ships; this says so when it has been switched on."
        case .threeFingerTap:
            return "The easiest to reach, and unclaimed on a stock Mac. Switching "
                 + "on Look Up by three-finger tap, or three-finger drag, is what "
                 + "takes the shape back — this says so when one of them has been."
        case .fourFingerTap:
            return "Nothing on the system binds a four-finger tap. Four fingers are "
                 + "Mission Control and Exposé only while they travel, and a tap "
                 + "that travels is not counted as one."
        case .fiveFingerTap:
            return "Hardest to fire by accident, hardest to reach on a small "
                 + "trackpad. The five-finger gesture macOS uses is a pinch, which "
                 + "travels, so a flat tap stays clear of it."
        case .threeFingerDoubleTap, .fourFingerDoubleTap:
            let fingers = fingerCount == 3 ? "Three" : "Four"
            return "\(fingers) fingers, twice, with no more than a short pause "
                 + "between. Practically impossible to trigger by resting a hand on "
                 + "the trackpad — at the price of having to mean it."
        }
    }

    /// A fresh recogniser for this shape.
    ///
    /// Two fingers are held to a shorter window than the rest. `maxDuration` is
    /// generous — 1.8s — because at three fingers and up the only thing it has
    /// to exclude is a hand resting on the trackpad, which is a deliberate act
    /// and runs longer still. Two fingers rest on a trackpad constantly and for
    /// no reason at all, so the same window admits every one of them. A tap that
    /// is over inside `twoFingerMaxDuration` is a tap; two fingers sitting there
    /// for longer than that are just two fingers sitting there.
    var recognizer: TapRecognizer {
        var recognizer = TapRecognizer(fingerCount: fingerCount, tapCount: tapCount)
        if fingerCount == 2 { recognizer.maxDuration = Self.twoFingerMaxDuration }
        return recognizer
    }

    /// Provisional, and the one number here that is not yet measured: the
    /// three-finger window came out of a 2629-frame trial, and this has had no
    /// equivalent. Deliberate two-finger taps observed so far land well inside
    /// it. If it turns out to reject real taps, the log at
    /// `~/Library/Logs/Recents-trackpad.log` says so in as many words —
    /// "rejected: held …s, limit …s" — which is what it is there for.
    static let twoFingerMaxDuration: Double = 0.6

    /// What this Mac is *currently* doing with the same shape, if anything.
    ///
    /// Read from the trackpad's own preference domains rather than assumed from
    /// the shipping defaults, because the one gesture in this list that can
    /// collide — three fingers — collides only when the user has switched
    /// something on themselves, and telling them that beats letting them
    /// discover it as a bug in this app.
    var systemConflict: String? {
        if fingerCount == 2, TrackpadSystemSettings.tapToClickIsOn {
            return "“Tap to click” is on, which makes a two-finger tap the "
                 + "secondary click — so this shape will open context menus too. "
                 + "Turn it off in Trackpad settings, or choose another shape."
        }
        guard fingerCount == 3 else { return nil }
        if TrackpadSystemSettings.threeFingerTapOpensLookUp {
            return "System Settings has “Look up & data detectors” set to a "
                 + "three-finger tap, so this shape will do both."
        }
        if TrackpadSystemSettings.threeFingerDragIsOn {
            return "Three-finger drag is on, so three fingers on the trackpad also "
                 + "move whatever is under the pointer."
        }
        return nil
    }
}

/// What the system itself has bound to trackpad gestures.
///
/// Read from the two domains the trackpad settings write to — the built-in
/// trackpad and a Magic Trackpad keep separate ones — so a warning reflects this
/// Mac rather than the defaults it shipped with. Absent keys mean off, which is
/// also what a Mac with no trackpad reports.
enum TrackpadSystemSettings {

    private static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]

    /// The largest value any trackpad's domain holds for the key. "Switched on
    /// for one of them" is the case that matters: either trackpad can be the one
    /// under the user's hand.
    static func setting(_ key: String) -> Int? {
        domains
            .compactMap { UserDefaults(suiteName: $0)?.object(forKey: key) as? Int }
            .max()
    }

    /// Tap-to-click. With it on, a light two-finger tap *is* the secondary
    /// click, and no amount of reading the button state can separate them —
    /// there is no button press to read. macOS ships with this off.
    static var tapToClickIsOn: Bool {
        (setting("Clicking") ?? 0) != 0
    }

    /// Look Up bound to a three-finger tap instead of a force click.
    static var threeFingerTapOpensLookUp: Bool {
        (setting("TrackpadThreeFingerTapGesture") ?? 0) != 0
    }

    /// Accessibility's three-finger drag, which makes three fingers a pointer
    /// gesture rather than a spare one.
    static var threeFingerDragIsOn: Bool {
        (setting("TrackpadThreeFingerDrag") ?? 0) != 0
    }
}

/// Turns raw contact frames into one callback on the main thread.
///
/// The framework calls back on a thread of its own at roughly the trackpad's
/// report rate, so nothing here may touch AppKit directly; the recognised
/// gesture is hopped to the main queue and everything else stays on the wire.
final class TrackpadGestureWatcher: @unchecked Sendable {

    static let shared = TrackpadGestureWatcher()

    /// Everything below the lock is written from the main thread and read on the
    /// framework's own contact thread, so all of it goes through the lock —
    /// including the two closures.
    ///
    /// The closures are the part that is easy to leave out and expensive to get
    /// wrong. Reading a strong reference while another thread assigns to it is
    /// not a stale-value bug, it is concurrent ARC on the same slot, which
    /// over-releases and crashes in `swift_release` with nothing left to connect
    /// it to the trackpad. `AppDelegate` reassigns `onGesture` every time the
    /// preference or the chosen gesture changes, which is precisely while frames
    /// may be arriving.
    private var storedRecognizer = SummonGesture.default.recognizer
    private var storedOnGesture: (() -> Void)?
    private var storedOnFrame: ((TouchFrame) -> Void)?
    private var storedLayoutLooksWrong = false
    /// When a finger-driven scroll last arrived. Written from the main thread by
    /// the event monitors, read on the contact thread — so, like everything else
    /// here, through the lock.
    private var storedLastScrollAt: Date = .distantPast
    private var scrollMonitors: [Any] = []
    /// Whether the first scroll of this run has been noted in the log.
    ///
    /// One line, once, and it earns its place: if the scroll monitors ever fail
    /// to install, the gesture goes straight back to reading every scroll as a
    /// tap — and that failure is invisible from outside, because a misfiring
    /// gesture and a working one look identical until the deck starts appearing
    /// on its own. This is the line that says the guard is live.
    private var storedLoggedFirstScroll = false

    /// How long after a scroll event the trackpad still counts as scrolling.
    ///
    /// A window rather than an exact answer, because scroll events arrive on the
    /// main run loop and the contacts arrive on their own thread; the two cannot
    /// be lined up precisely and do not need to be. Long enough to cover the gap
    /// between one scroll event and the next, short enough that a deliberate tap
    /// straight after a scroll is still read as a tap.
    private static let scrollMemory: TimeInterval = 0.3

    var recognizer: TapRecognizer {
        get { lock.lock(); defer { lock.unlock() }; return storedRecognizer }
        set { lock.lock(); storedRecognizer = newValue; lock.unlock() }
    }

    /// Called on the main thread when the gesture fires.
    var onGesture: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedOnGesture }
        set { lock.lock(); storedOnGesture = newValue; lock.unlock() }
    }

    /// Every frame, for the self-test. Called on the framework's own thread.
    var onFrame: ((TouchFrame) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storedOnFrame }
        set { lock.lock(); storedOnFrame = newValue; lock.unlock() }
    }

    static var isAvailable: Bool { MultitouchSupport.isAvailable }

    /// Which shape is bound is the user's choice — see `SummonGesture`, and
    /// `AppDelegate.applyTrackpadGesture`, which installs the matching
    /// recogniser whenever that choice changes.

    /// Diagnostics for a path with no visible failure mode: a watcher that is
    /// not running, a device that was never started and a gesture that is not
    /// recognised all look identical from outside — nothing happens.
    ///
    /// A file rather than `os_log`, because the unified log returned nothing
    /// for this process even with `--info --debug`, and a diagnostic you
    /// cannot read is not a diagnostic. Written only while the gesture is
    /// switched on, so it costs nothing for everyone else.
    static let log = TrackpadLog()

    private let lock = NSLock()
    /// Held, not just read — see `MultitouchSupport.DeviceList`.
    private var deviceList = MultitouchSupport.DeviceList.empty
    private var isRunning = false

    /// True once a frame has arrived whose contacts do not survive validation,
    /// which means the assumed struct layout no longer matches this OS. Set on
    /// the contact thread and read by the self-test on the main one.
    var contactLayoutLooksWrong: Bool {
        lock.lock(); defer { lock.unlock() }; return storedLayoutLooksWrong
    }

    private init() {}

    /// Starts listening. Returns the number of devices actually started, so a
    /// caller can tell "no trackpad" apart from "refused".
    @discardableResult
    func start() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard !isRunning, MultitouchSupport.isAvailable else {
            return deviceList.devices.count
        }

        deviceList = MultitouchSupport.deviceList()
        for device in deviceList.devices {
            MultitouchSupport.register(device, Self.trampoline)
            MultitouchSupport.start(device)
        }
        storedLoggedFirstScroll = false
        installScrollMonitors()
        isRunning = !deviceList.devices.isEmpty
        Self.log.write("watcher started: \(self.deviceList.devices.count) device(s), watching \(self.storedRecognizer.fingerCount) fingers x\(self.storedRecognizer.tapCount)")
        return deviceList.devices.count
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard isRunning else { return }
        for device in deviceList.devices {
            MultitouchSupport.unregister(device, Self.trampoline)
            MultitouchSupport.stop(device)
        }
        deviceList = .empty
        isRunning = false
        scrollMonitors.forEach(NSEvent.removeMonitor)
        scrollMonitors.removeAll()
    }

    /// Notes when the system is scrolling, so the recogniser can refuse to read
    /// a scroll as a tap.
    ///
    /// Both monitors: a global one sees scrolls aimed at every other
    /// application, which is where they nearly always go, and a local one covers
    /// the deck's own window — a global monitor is blind to its own process.
    ///
    /// Momentum is deliberately not counted. It carries on for a second or more
    /// after the fingers have left the trackpad, and treating it as scrolling
    /// would make the gesture unreachable for exactly as long as a flick keeps
    /// coasting.
    private func installScrollMonitors() {
        // Idempotent, because `start()` is not. `start()` returns early only
        // once `isRunning` has latched, and `isRunning` stays false when the
        // device list came back empty — so on a Mac with no trackpad every call
        // reached this and appended another pair, while the pair before it was
        // never removed and went on running the handler for every scroll.
        guard scrollMonitors.isEmpty else { return }

        let note: (NSEvent) -> Void = { event in
            guard event.momentumPhase == [] else { return }
            let watcher = TrackpadGestureWatcher.shared
            watcher.lock.lock()
            watcher.storedLastScrollAt = Date()
            let isFirst = !watcher.storedLoggedFirstScroll
            watcher.storedLoggedFirstScroll = true
            watcher.lock.unlock()
            if isFirst {
                Self.log.write("scroll guard live — scrolls will not be read as taps")
            }
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: note) {
            scrollMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: {
            note($0)
            return $0
        }) {
            scrollMonitors.append(local)
        }
    }

    /// Whether any mouse button is physically down right now.
    ///
    /// `CGEventSource` rather than `NSEvent.pressedMouseButtons`, because this is
    /// read on the framework's own contact thread and AppKit is not to be touched
    /// from there. Sampled per frame rather than watched as an event for the same
    /// reason: an `NSEvent` monitor is delivered on the main run loop, and a busy
    /// main thread would let the answer arrive after the fingers had already
    /// lifted — which is the one moment it has to be right. Measured at 0.01µs a
    /// call, against frames that arrive around a hundred times a second.
    private static func anyMouseButtonIsDown() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
            || CGEventSource.buttonState(.combinedSessionState, button: .center)
    }

    /// A C function pointer cannot capture context, so the callback routes
    /// through the shared instance.
    private static let trampoline: MultitouchSupport.ContactCallback = {
        _, touches, count, timestamp, _ in
        shared.handle(touches: touches, count: Int(count), timestamp: timestamp)
        return 0
    }

    private func handle(
        touches: UnsafeMutableRawPointer?, count: Int, timestamp: Double
    ) {
        var layoutLooksWrong = false
        var positions: [MultitouchSupport.Point] = []
        if let touches, count > 0 {
            positions.reserveCapacity(count)
            for index in 0..<count {
                let offset = index * MultitouchSupport.Contact.stride
                    + MultitouchSupport.Contact.normalizedPositionOffset
                let x = touches.loadUnaligned(fromByteOffset: offset, as: Float.self)
                let y = touches.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                // The layout check: a normalised coordinate outside 0…1 means we
                // are reading the wrong bytes, and every position this frame is
                // suspect. Counting fingers does not depend on the layout, so the
                // rest of the recogniser keeps working without them.
                guard x.isFinite, y.isFinite,
                      x >= -0.05, x <= 1.05, y >= -0.05, y <= 1.05
                else {
                    layoutLooksWrong = true
                    positions = []
                    break
                }
                positions.append(MultitouchSupport.Point(x: x, y: y))
            }
        }

        var frame = TouchFrame(
            fingerCount: count, timestamp: timestamp, positions: positions,
            isClicking: Self.anyMouseButtonIsDown()
        )

        // Everything the lock guards, read and written in one pass — including
        // the two handlers, which are then called *outside* it. Holding a lock
        // across a callback is how a caller that touches this object from its own
        // handler deadlocks, and `NSLock` is not recursive.
        lock.lock()
        if layoutLooksWrong { storedLayoutLooksWrong = true }
        frame.isScrolling =
            Date().timeIntervalSince(storedLastScrollAt) < Self.scrollMemory
        let onFrame = storedOnFrame
        let onGesture = storedOnGesture
        let outcome = storedRecognizer.accept(frame)
        let wanted = storedRecognizer.fingerCount
        let wantedTaps = storedRecognizer.tapCount
        lock.unlock()

        onFrame?(frame)

        var fired = false
        switch outcome {
        case .pending:
            break
        case .recognised:
            fired = true
        case .partial(let done, let total):
            Self.log.write("\(wanted)-finger tap \(done) of \(total); waiting for the next")
        case .rejected(let reason):
            Self.log.write("rejected: \(reason)")
        }

        if fired {
            let shape = "\(wanted)-finger \(wantedTaps > 1 ? "double tap" : "tap")"
            Self.log.write("recognised a \(shape); handler \(onGesture == nil ? "MISSING" : "set")")
        }

        if fired, let onGesture {
            DispatchQueue.main.async(execute: onGesture)
        }
    }
}

/// Appends a line to `~/Library/Logs/Recents-trackpad.log`.
///
/// Deliberately dumb: opened per write, no buffering, safe from any thread. It
/// exists to answer "did this code run at all", and a diagnostic that needs its
/// own debugging is worthless.
final class TrackpadLog: @unchecked Sendable {

    static let url = URL(
        fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Recents-trackpad.log"
    )

    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: Self.url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: Self.url)
        }
    }
}
