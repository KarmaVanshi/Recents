import AppKit
import ApplicationServices
import Combine

/// Measures how far the highlight runs behind a pointer sweeping along a Dock
/// preview's row of thumbnails.
///
/// Run: `Recents.app/Contents/MacOS/Recents --selftest-dock-sweep`
///
/// "The highlight lags the pointer" is a complaint about a pipeline with four
/// stages, and reading the code cannot say which one is slow: the mouse-moved
/// event has to be delivered to a panel that is never key, the controller has
/// to turn it into a selection, SwiftUI has to rebuild the row around the new
/// highlight, and Core Animation has to hand the result to the window server.
/// So this raises a panel the way a user does — by resting the pointer on a
/// tile and letting `DockHoverWatcher` report it — then drives the pointer up
/// into the row and along it at the rate a mouse reports, the instant the panel
/// is up, and stamps each stage as it happens:
///
/// - **delivery** — the age of each mouse-moved event when the app receives it,
///   which is how long it sat in the queue behind whatever the main thread was
///   doing, and how many arrived at all;
/// - **selection** — the moment `select` writes the new index, against the
///   moment the pointer was put over that thumbnail;
/// - **commit** — the end of the run-loop turn in which SwiftUI rebuilt the row
///   and Core Animation committed it, after which the next display refresh
///   shows it.
///
/// Alongside, every turn of the main run loop is timed, so a stall shows up as
/// a number rather than as a feeling. The pointer is driven from a background
/// queue on purpose: a timer on the main run loop would be held up by the very
/// stalls being measured and would sweep more slowly through them, which is
/// exactly the kind of instrument that flatters the thing it is measuring.
///
/// The first thing it caught was not a stall at all. The main thread was idle
/// and the few events that arrived were answered in a frame; what was wrong was
/// that only a handful arrived, because the watcher's global mouse-moved monitor
/// was starving this app's own panel of them. The count of events reaching the
/// panel is therefore reported alongside the latencies — it is the number that
/// told the two apart.
@MainActor
enum DockSweepSelfTest {

    /// One thumbnail crossed: when the pointer was put on it, when the highlight
    /// followed, and when the frame showing that went out.
    private struct Crossing {
        let index: Int
        let entered: TimeInterval
        var selected: TimeInterval?
        var committed: TimeInterval?
    }

    /// One thumbnail's column on screen, in Cocoa coordinates: the picture and
    /// the caption under it, exactly the region `DockPreviewLayout` resolves to
    /// that thumbnail.
    private struct Column: Sendable {
        let index: Int
        let rect: CGRect
    }

    /// One straight movement of the pointer.
    private struct Leg: Sendable {
        let from: CGPoint
        let to: CGPoint
        let duration: TimeInterval
    }

    /// One turn of the main run loop, and how long it took.
    private struct Turn {
        let at: TimeInterval
        let duration: TimeInterval
    }

    private static var crossings: [Crossing] = []
    private static var eventAges: [TimeInterval] = []
    private static var turns: [Turn] = []
    private static var turnBegan: TimeInterval?
    private static var sweepBegan: TimeInterval = 0
    private static var sweepEnded: TimeInterval = .infinity
    private static var subscription: AnyCancellable?

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        print("Dock preview pointer sweep — self test\n")

        guard AXIsProcessTrusted() else {
            print("  ✗ Accessibility is not granted to this bundle, so the Dock")
            print("    cannot be read. Grant it in System Settings › Privacy &")
            print("    Security › Accessibility.")
            exit(1)
        }

        guard let strip = DockProbe.stripFrame() else {
            print("  ✗ The Dock's tile strip could not be located.")
            exit(1)
        }

        // The tile with the most windows behind it: the more thumbnails the
        // sweep crosses, the more crossings there are to measure.
        var chosen: (tile: DockProbe.Tile, count: Int)?
        var distance: CGFloat = 0
        let isVertical = strip.height > strip.width
        let length = isVertical ? strip.height : strip.width
        while distance <= length {
            let point = isVertical
                ? CGPoint(x: strip.midX, y: strip.maxY - distance)
                : CGPoint(x: strip.minX + distance, y: strip.midY)
            distance += 8
            guard let tile = DockProbe.tile(at: point),
                  !(chosen?.tile.isSameTile(as: tile) ?? false),
                  let target = DockWindows.target(for: tile),
                  target.windows.count > (chosen?.count ?? 1)
            else { continue }
            chosen = (tile, target.windows.count)
        }

        guard let chosen else {
            print("  ✗ No Dock tile has two or more windows behind it, so there is")
            print("    no row to sweep along. Open a second window in some app and")
            print("    run this again.")
            exit(1)
        }
        print("  Tile                : \"\(chosen.tile.title)\" — \(chosen.count) windows")

        guard DockPreviewController.shared.isEnabled else {
            print("  ✗ Dock previews are switched off in Settings, so the hover")
            print("    watcher will not raise one. Switch them on and run this again.")
            exit(1)
        }
        DockPreviewController.shared.start()
        instrument()

        let restore = NSEvent.mouseLocation
        let tileCentre = CGPoint(x: chosen.tile.frame.midX, y: chosen.tile.frame.midY)

        step(0.5) {
            move(to: tileCentre)
            let arrivedOnTile = now
            awaitPanel(deadline: now + 3) { panel, layout in
                print("  Panel               : \(Int(panel.frame.width))×\(Int(panel.frame.height))"
                    + " at (\(Int(panel.frame.minX)), \(Int(panel.frame.minY))), "
                    + "up \(ms(now - arrivedOnTile)) ms after the pointer reached the tile")
                print("  Thumbnails          : \(layout.widths.count), "
                    + "\(layout.widths.map { Int($0) }) wide")

                // A column runs from the top of its picture to the bottom of
                // the panel, as `DockPreviewLayout.thumbnailIndex` has it. The
                // sweep runs along the middle of the pictures.
                let top = panel.frame.maxY
                    - (DockPreviewLayout.padding + DockPreviewLayout.headerHeight
                        + DockPreviewLayout.headerGap)
                var left = panel.frame.minX + DockPreviewLayout.padding
                let columns: [Column] = layout.widths.enumerated().map { index, width in
                    defer { left += width + DockPreviewLayout.spacing }
                    return Column(index: index, rect: CGRect(
                        x: left, y: panel.frame.minY, width: width, height: top - panel.frame.minY
                    ))
                }
                let line = top - layout.height / 2
                let leftEnd = CGPoint(x: panel.frame.minX + DockPreviewLayout.padding / 2, y: line)
                let rightEnd = CGPoint(x: panel.frame.maxX - DockPreviewLayout.padding / 2, y: line)
                // Straight up from the tile into the row, then along it, back,
                // and along it again.
                let entry = CGPoint(x: min(max(tileCentre.x, leftEnd.x), rightEnd.x), y: line)
                let path = [
                    Leg(from: tileCentre, to: entry, duration: 0.15),
                    Leg(from: entry, to: rightEnd,
                        duration: sweepDuration * (rightEnd.x - entry.x) / panel.frame.width),
                    Leg(from: rightEnd, to: leftEnd, duration: sweepDuration),
                    Leg(from: leftEnd, to: rightEnd, duration: sweepDuration),
                ]

                sweepBegan = now
                drive(path, columns: columns) {
                    step(0.4) {
                        sweepEnded = now
                        move(to: restore)
                        report()
                    }
                }
            }
        }

        NSApp.run()
    }

    // MARK: - Instruments

    private static func instrument() {
        // Delivery: how old each mouse-moved event is by the time this process
        // sees it, which is the queueing delay behind the main thread's work —
        // and, by their number, whether they are arriving at all.
        _ = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            MainActor.assumeIsolated { eventAges.append(now - event.timestamp) }
            return event
        }

        // Selection: the instant the highlight is written. Attributed to the
        // most recent crossing that has not been selected yet — the pointer is
        // never on two thumbnails at once, so that is the one it belongs to.
        subscription = DockPreviewController.shared.selectionChanges.sink { index in
            MainActor.assumeIsolated {
                guard let index,
                      let slot = crossings.lastIndex(where: { $0.index == index && $0.selected == nil })
                else { return }
                crossings[slot].selected = now
            }
        }

        // Commit, and the length of every turn. Registered after Core
        // Animation's own commit observer (order 2 000 000), so by the time this
        // runs the frame with the new highlight in it has been handed to the
        // window server — and the time since the loop woke is what the whole
        // turn cost.
        let activities = CFRunLoopActivity.afterWaiting.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 2_100_000) {
            _, activity in
            MainActor.assumeIsolated {
                switch activity {
                case .afterWaiting:
                    turnBegan = now
                case .beforeWaiting:
                    let finished = now
                    for slot in crossings.indices
                    where crossings[slot].selected != nil && crossings[slot].committed == nil {
                        crossings[slot].committed = finished
                    }
                    if let began = turnBegan {
                        turns.append(Turn(at: began, duration: finished - began))
                    }
                    turnBegan = nil
                default:
                    break
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    // MARK: - Driving the pointer

    /// Report rate of an ordinary mouse. A sweep across the row at this rate
    /// lands on every thumbnail several times, so a crossing is never lost to
    /// the pointer jumping clean over a picture.
    private static let reportInterval: TimeInterval = 0.008

    /// A brisk pass across the row — the speed of a hand comparing three
    /// windows, not a flick.
    private static let sweepDuration: TimeInterval = 0.6

    /// Waits for the watcher to raise the panel, checking often enough that
    /// the moment it appears is not missed by much.
    private static func awaitPanel(
        deadline: TimeInterval, _ then: @escaping (NSWindow, DockPreviewLayout) -> Void
    ) {
        if let panel = NSApp.windows.first(where: { $0.isVisible && $0 is DockPreviewPanel }),
           let layout = DockPreviewController.shared.shownLayout {
            then(panel, layout)
            return
        }
        guard now < deadline else {
            print("  ✗ The pointer rested on the tile for three seconds and no")
            print("    panel appeared.")
            exit(1)
        }
        step(0.004) { awaitPanel(deadline: deadline, then) }
    }

    /// Moves the pointer along the legs at a steady report rate, from a
    /// background queue so a stalled main thread cannot slow the hand down.
    /// Each time the pointer is put on a column it was not on before, that is
    /// written down as a crossing.
    private static func drive(
        _ legs: [Leg], columns: [Column], then completion: @escaping () -> Void
    ) {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let queue = DispatchQueue(label: "com.recents.deck.sweep", qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var leg = 0
        var step = 0
        var over: Int?
        timer.schedule(deadline: .now(), repeating: reportInterval, leeway: .microseconds(500))
        timer.setEventHandler {
            let current = legs[leg]
            let steps = max(Int(current.duration / reportInterval), 1)
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: current.from.x + (current.to.x - current.from.x) * t,
                y: current.from.y + (current.to.y - current.from.y) * t
            )
            let stamped = ProcessInfo.processInfo.systemUptime
            CGEvent(
                mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: point.x, y: primaryHeight - point.y),
                mouseButton: .left
            )?.post(tap: .cghidEventTap)

            let index = columns.first { $0.rect.contains(point) }?.index
            if index != over {
                over = index
                if let index {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            crossings.append(Crossing(index: index, entered: stamped))
                        }
                    }
                }
            }

            step += 1
            if step > steps {
                step = 0
                leg += 1
                if leg == legs.count {
                    timer.cancel()
                    DispatchQueue.main.async { MainActor.assumeIsolated(completion) }
                }
            }
        }
        timer.resume()
        // Held by the handler's own capture until it cancels itself.
        _ = timer
    }

    // MARK: - Reporting

    private static func report() -> Never {
        subscription = nil
        DockPreviewController.shared.stop()

        print("")
        print("  Each thumbnail the pointer was put on, and how long the highlight")
        print("  took to follow. `select` is when the controller wrote the new")
        print("  index; `commit` is when the frame showing it left for the window")
        print("  server. Both are measured from the pointer arriving.")
        print("")
        print("  THUMB  ARRIVED   SELECT   COMMIT")

        var selectLatencies: [TimeInterval] = []
        var commitLatencies: [TimeInterval] = []
        var missed = 0
        for crossing in crossings {
            let arrived = crossing.entered - sweepBegan
            let select = crossing.selected.map { $0 - crossing.entered }
            let commit = crossing.committed.map { $0 - crossing.entered }
            if let select { selectLatencies.append(select) } else { missed += 1 }
            if let commit { commitLatencies.append(commit) }
            print("  \(String(crossing.index).padded(to: 7))"
                + "\(ms(arrived).padded(to: 10))"
                + "\((select.map(ms).map { "+" + $0 } ?? "—").padded(to: 9))"
                + "\(commit.map(ms).map { "+" + $0 } ?? "—")")
        }
        print("")

        let duringSweep = turns.filter { $0.at >= sweepBegan && $0.at <= sweepEnded }
        let durations = duringSweep.map(\.duration)
        print("  Crossings           : \(crossings.count), \(missed) never highlighted")
        if !selectLatencies.isEmpty {
            print("  Pointer → select    : median \(ms(median(selectLatencies))) ms, "
                + "max \(ms(selectLatencies.max() ?? 0)) ms")
        }
        if !commitLatencies.isEmpty {
            print("  Pointer → commit    : median \(ms(median(commitLatencies))) ms, "
                + "max \(ms(commitLatencies.max() ?? 0)) ms")
        }
        if eventAges.isEmpty {
            print("  Mouse-moved events  : none reached the panel")
        } else {
            print("  Mouse-moved events  : \(eventAges.count) reached the panel, "
                + "median \(ms(median(eventAges))) ms old on arrival, "
                + "max \(ms(eventAges.max() ?? 0)) ms")
        }
        if !durations.isEmpty {
            print("  Main-thread turns   : \(duringSweep.count) during the sweep, "
                + "longest \(ms(durations.max() ?? 0)) ms, "
                + "\(durations.filter { $0 > 1.0 / 60 }.count) over a frame")
        }
        print("")

        guard !crossings.isEmpty else {
            print("  ✗ The pointer was never put on a thumbnail.")
            exit(1)
        }
        guard missed == 0 else {
            print("  ✗ \(missed) crossing(s) never moved the highlight at all. The")
            print("    events are not reaching the panel — see the count above.")
            exit(1)
        }

        // A commit within two display frames of the pointer arriving is what
        // "follows the pointer" means; a hand does not notice less than that.
        // Two rather than one because the window server hands mouse-moved
        // events to a window once per display refresh, so half a frame of the
        // budget is spent before the app hears anything.
        let budget = 2.0 / 60
        let slow = commitLatencies.filter { $0 > budget }
        guard slow.isEmpty else {
            print("  ✗ \(slow.count) of \(commitLatencies.count) crossings took more than")
            print("    two frames (\(ms(budget)) ms) from pointer to commit.")
            exit(1)
        }
        print("  ✓ The highlight follows the pointer within two frames.")
        exit(0)
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds * 1000)
    }

    private static func step(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated(work)
        }
    }

    /// Flipped about the primary display's height, as `DockKeySelfTest` does
    /// and for the same reason.
    private static func move(to point: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: point.x, y: primaryHeight - point.y),
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }
}
