import AppKit
import Testing
@testable import Recents

/// How long a Dock preview's frames outlive the panel that captured them.
///
/// The claim is a balance rather than a rule in one direction, which is why it
/// is worth pinning: keep a panel's frames and the tile you just left redraws
/// complete; keep every panel's frames and the process holds one window backing
/// store per window ever hovered — and, because those are the window server's
/// own surfaces, keeps other applications' closed windows resident too.
@Suite("LiveWindowPreview frame retention")
@MainActor
struct LiveWindowPreviewTests {

    private let first: CGWindowID = 900_001
    private let second: CGWindowID = 900_002

    private func frame() -> NSImage { NSImage(size: NSSize(width: 1, height: 1)) }

    /// The engine is a singleton, so each test starts by forgetting the windows
    /// it is about to use and ends by forgetting them again.
    private func withCleanSlate(_ body: (LiveWindowPreview) -> Void) {
        let engine = LiveWindowPreview.shared
        engine.forgetWindow(first)
        engine.forgetWindow(second)
        body(engine)
        engine.forgetWindow(first)
        engine.forgetWindow(second)
    }

    @Test("The panel just dismissed keeps its frames, so returning to that tile redraws complete")
    func theLastPanelIsKept() {
        withCleanSlate { engine in
            let slot = engine.slot(forWindow: first)
            engine.setDemand(.focused, forWindow: first)
            slot.image = frame()

            engine.clearWindowDemands()

            #expect(slot.image != nil)
            #expect(slot.isLive == false)
        }
    }

    @Test("A panel two hovers back does not, so frames cannot accumulate across a session")
    func olderPanelsAreDropped() {
        withCleanSlate { engine in
            let older = engine.slot(forWindow: first)
            engine.setDemand(.focused, forWindow: first)
            older.image = frame()

            // Hovering the next tile: the first panel's frames are still the
            // ones "the tile I just left" would need.
            engine.clearWindowDemands()
            let newer = engine.slot(forWindow: second)
            engine.setDemand(.focused, forWindow: second)
            newer.image = frame()
            #expect(older.image != nil)

            // Hovering a third: the first panel is now out of reach of any
            // gesture, and its window's backing store goes with it.
            engine.clearWindowDemands()
            #expect(newer.image != nil)
            #expect(older.image == nil)
        }
    }

    @Test("A window still being followed keeps its frame however often the panel re-forms")
    func followedWindowsAreUntouched() {
        withCleanSlate { engine in
            let slot = engine.slot(forWindow: first)
            engine.setDemand(.focused, forWindow: first)
            slot.image = frame()

            engine.clearWindowDemands()
            // What `show` does next: the same window, re-subscribed.
            engine.setDemand(.focused, forWindow: first)
            engine.clearWindowDemands()

            #expect(slot.image != nil)
        }
    }
}
