import AppKit

/// Proves the trackpad gesture path end to end, from the terminal.
///
/// Run: `Recents --selftest-gesture`
///
/// It scores whichever gesture Settings currently has bound. `--fingers 4` and
/// `--taps 2` override that, for trying a shape on before choosing it.
///
/// Two questions have to be answered on the machine rather than from
/// documentation, and neither can be answered without a hand on the trackpad:
///
///   1. Do contact frames arrive at all? `MultitouchSupport` is private SPI and
///      raw input is exactly the sort of thing recent releases have moved behind
///      an Input Monitoring grant. If frames never arrive, the whole approach is
///      dead and the answer is a third-party gesture utility instead.
///   2. Does a four-finger tap separate cleanly from the *start* of a four-finger
///      swipe? Those swipes are Mission Control and App Exposé, and a summon that
///      fired on the way into either would be worse than no gesture at all.
///
/// So it prints what the framework reports, live, and scores each gesture
/// against the same `TapRecognizer` the app would use — not a private copy of
/// the logic, which would prove nothing about the app.
@MainActor
enum TrackpadGestureSelfTest {

    private static let duration: TimeInterval = 45

    static func run() {
        // The framework wants a running application, and this keeps the process
        // out of the Dock while it listens.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        print("Trackpad gesture — self test\n")

        let recognizer = requestedRecognizer()
        let fingers = recognizer.fingerCount
        let shape = "\(fingers)-finger \(recognizer.tapCount > 1 ? "double tap" : "tap")"
        print("  MultitouchSupport available : \(MultitouchSupport.isAvailable ? "yes" : "NO")")

        guard MultitouchSupport.isAvailable else {
            print("\n  ✗ The framework or one of its symbols is missing on this OS.")
            print("    A trackpad summon is not available; use the hotkey or the menu bar.")
            exit(1)
        }

        // Bound to a local rather than used inline: the handles are borrowed
        // from this list, and a temporary would release them before the next
        // line reads one — the same trap `DeviceList` documents.
        let list = MultitouchSupport.deviceList()
        let devices = list.devices
        print("  Multitouch devices          : \(devices.count)"
            + (devices.isEmpty ? "" : "  (\(devices.filter(MultitouchSupport.isBuiltIn).count) built in)"))
        print("  Watching for                : a \(shape)")

        guard !devices.isEmpty else {
            print("\n  ✗ No multitouch device. A Magic Trackpad or a built-in one is required.")
            exit(1)
        }

        let watcher = TrackpadGestureWatcher.shared
        watcher.recognizer = recognizer

        let state = Recorder()
        watcher.onFrame = { frame in state.record(frame) }
        watcher.onGesture = { state.recordGesture() }

        let started = watcher.start()
        print("  Devices started             : \(started)\n")

        print("  Put \(fingers) fingers on the trackpad and lift them"
            + (recognizer.tapCount > 1 ? ", twice in a row" : "") + " — that is the gesture.")
        print("  Then try a \(fingers)-finger swipe (Mission Control) a few times: those")
        print("  must NOT register. \(Int(duration)) seconds.\n")

        // A live line rather than a scrolling log: at the trackpad's report rate
        // a line per frame would be unreadable.
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            state.printStatus()
        }
        RunLoop.main.add(ticker, forMode: .common)

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            ticker.invalidate()
            watcher.stop()
            report(state, fingers: fingers, watcher: watcher)
        }

        NSApp.run()
    }

    /// The recogniser the app itself would install, unless the command line
    /// asks for another shape. Testing the bound gesture by default is the point
    /// — a self-test of a gesture nobody uses proves nothing about the one they
    /// do.
    private static func requestedRecognizer() -> TapRecognizer {
        var recognizer = Preferences.shared.summonGesture.recognizer
        if let fingers = intArgument("--fingers"), (2...5).contains(fingers) {
            recognizer.fingerCount = fingers
        }
        if let taps = intArgument("--taps"), (1...2).contains(taps) {
            recognizer.tapCount = taps
        }
        return recognizer
    }

    private static func intArgument(_ name: String) -> Int? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              CommandLine.arguments.count > index + 1
        else { return nil }
        return Int(CommandLine.arguments[index + 1])
    }

    private static func report(_ state: Recorder, fingers: Int, watcher: TrackpadGestureWatcher) {
        let s = state.snapshot()
        print("\u{001B}[2K\r")
        print("  Frames received             : \(s.frames)")
        print("  Peak fingers seen           : \(s.peakFingers)")
        print("  Contact positions           : "
            + (watcher.contactLayoutLooksWrong
                ? "UNRELIABLE — the struct layout has moved"
                : (s.sawPositions ? "valid (0…1 as expected)" : "none seen")))
        print("  Taps recognised             : \(s.gestures)")

        guard s.frames > 0 else {
            print("\n  ✗ No frames arrived.")
            print("    Two readings, and they need telling apart: either nobody")
            print("    touched the trackpad during the window, or raw input is being")
            print("    withheld. Run it again and be sure to touch the trackpad. If")
            print("    it is still silent, check System Settings ▸ Privacy & Security")
            print("    ▸ Input Monitoring — and run it from the signed bundle, since")
            print("    a grant follows the app's identity, not a loose binary.")
            exit(1)
        }

        guard s.peakFingers >= fingers else {
            print("\n  ⚠︎ Frames are arriving, but \(fingers) fingers were never seen at once")
            print("    (peak was \(s.peakFingers)). Run it again and rest all \(fingers) down together.")
            exit(1)
        }

        if s.gestures == 0 {
            print("\n  ⚠︎ Fingers are being read, but no gesture was recognised.")
            print("    The thresholds are probably too tight — hold time, travel and,")
            print("    for a double tap, the gap between the two are the ones to loosen")
            print("    in `TapRecognizer`. `~/Library/Logs/Recents-trackpad.log` says")
            print("    which of them threw each attempt out.")
            exit(1)
        }

        print("\n  ✓ \(s.gestures) tap\(s.gestures == 1 ? "" : "s") recognised from \(s.frames) frames.")
        if watcher.contactLayoutLooksWrong {
            print("    The travel test was inactive — positions did not validate, so a")
            print("    slow swipe could still register. Worth fixing before wiring it up.")
        }
        print("    If any of your swipes registered as taps, tighten `maxDuration`")
        print("    or `maxTravel`; if none did, this is ready to bind.")
        exit(0)
    }

    /// Frames arrive on the framework's own thread, so every counter it touches
    /// is behind a lock rather than assumed to be main-thread.
    private final class Recorder: @unchecked Sendable {
        struct Snapshot {
            var frames = 0
            var peakFingers = 0
            var gestures = 0
            var current = 0
            var sawPositions = false
        }

        private let lock = NSLock()
        private var state = Snapshot()

        func record(_ frame: TouchFrame) {
            lock.lock(); defer { lock.unlock() }
            state.frames += 1
            state.current = frame.fingerCount
            state.peakFingers = max(state.peakFingers, frame.fingerCount)
            if !frame.positions.isEmpty { state.sawPositions = true }
        }

        func recordGesture() {
            lock.lock(); defer { lock.unlock() }
            state.gestures += 1
        }

        func snapshot() -> Snapshot {
            lock.lock(); defer { lock.unlock() }
            return state
        }

        func printStatus() {
            let s = snapshot()
            let dots = String(repeating: "●", count: s.current)
                + String(repeating: "·", count: max(0, 5 - s.current))
            print("\u{001B}[2K\r  fingers \(dots)   frames \(s.frames)"
                + "   taps \(s.gestures)", terminator: "")
            fflush(stdout)
        }
    }
}
