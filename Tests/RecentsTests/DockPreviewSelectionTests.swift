import Foundation
import Testing
@testable import Recents

/// Where the arrow keys move the highlight in a Dock preview.
///
/// The panel this serves never becomes the key window, so these keys are read
/// from an event tap and taken away from whatever application is actually in
/// front — which makes "what does this key do" a question worth answering
/// exactly, including in the cases nobody hovers on purpose: an empty row, a row
/// of one, and both ends of a row.
@Suite("DockPreviewSelection")
struct DockPreviewSelectionTests {

    private func step(from index: Int?, by delta: Int, count: Int) -> Int? {
        DockPreviewSelection.stepping(from: index, by: delta, count: count)
    }

    // MARK: - Getting into the row

    @Test("→ with nothing chosen takes the first thumbnail")
    func rightEntersAtTheStart() {
        #expect(step(from: nil, by: 1, count: 4) == 0)
    }

    @Test("← with nothing chosen takes the last, so either key gets you in")
    func leftEntersAtTheEnd() {
        #expect(step(from: nil, by: -1, count: 4) == 3)
    }

    // MARK: - Moving along it

    @Test("→ steps to the next thumbnail")
    func rightAdvances() {
        #expect(step(from: 0, by: 1, count: 4) == 1)
        #expect(step(from: 2, by: 1, count: 4) == 3)
    }

    @Test("← steps back")
    func leftRetreats() {
        #expect(step(from: 3, by: -1, count: 4) == 2)
        #expect(step(from: 1, by: -1, count: 4) == 0)
    }

    // MARK: - The ends

    /// The whole row is on screen at once, so wrapping would move the highlight
    /// the length of the panel in the one gesture meant to walk along it.
    @Test("The ends hold rather than wrapping round")
    func endsDoNotWrap() {
        #expect(step(from: 3, by: 1, count: 4) == 3)
        #expect(step(from: 0, by: -1, count: 4) == 0)
    }

    @Test("A row of one has nowhere to go and stays put")
    func singleThumbnailHolds() {
        #expect(step(from: 0, by: 1, count: 1) == 0)
        #expect(step(from: 0, by: -1, count: 1) == 0)
        #expect(step(from: nil, by: 1, count: 1) == 0)
        #expect(step(from: nil, by: -1, count: 1) == 0)
    }

    /// Nil rather than an index, and the distinction matters beyond tidiness:
    /// it is what tells the controller the key was not used, so the keystroke is
    /// handed back to the application in front instead of being swallowed by a
    /// panel with nothing in it.
    @Test("An empty row refuses the key instead of inventing an index")
    func emptyRowRefuses() {
        #expect(step(from: nil, by: 1, count: 0) == nil)
        #expect(step(from: nil, by: -1, count: 0) == nil)
        #expect(step(from: 0, by: 1, count: 0) == nil)
    }

    /// A row can be rebuilt shorter underneath a highlight — closing one of two
    /// windows from a thumbnail does exactly that — and an index left pointing
    /// past the end must not survive the next keystroke.
    @Test("An index past the end of a shortened row is pulled back into it")
    func staleIndexIsClamped() {
        #expect(step(from: 5, by: 1, count: 2) == 1)
        #expect(step(from: 5, by: -1, count: 2) == 1)
    }

    // MARK: - Whose keys are they

    private let panel = CGRect(x: 100, y: 200, width: 400, height: 300)

    @Test("A pointer on the panel means the keys were aimed at the panel")
    func pointerOnThePanelOwnsTheKeys() {
        #expect(DockPreviewSelection.panelOwnsKeyboard(
            panel: panel, pointer: CGPoint(x: 300, y: 350)
        ))
    }

    @Test("A pointer anywhere else leaves the keys to the application in front")
    func pointerOffThePanelDoesNot() {
        // The bug this rule exists for: a preview appears from resting the
        // pointer near the Dock, and every key it answers is a key taken out of
        // whatever the user is typing into. The tile itself counts as off — that
        // is someone looking at a preview, not driving it.
        #expect(!DockPreviewSelection.panelOwnsKeyboard(
            panel: panel, pointer: CGPoint(x: 300, y: 100)
        ))
        #expect(!DockPreviewSelection.panelOwnsKeyboard(
            panel: panel, pointer: CGPoint(x: 0, y: 0)
        ))
    }

    @Test("A pointer resting on the very edge still counts as on the panel")
    func theEdgeIsForgiving() {
        #expect(DockPreviewSelection.panelOwnsKeyboard(
            panel: panel, pointer: CGPoint(x: 100, y: 200), margin: 6
        ))
        #expect(DockPreviewSelection.panelOwnsKeyboard(
            panel: panel, pointer: CGPoint(x: 97, y: 200), margin: 6
        ))
        #expect(!DockPreviewSelection.panelOwnsKeyboard(
            panel: panel, pointer: CGPoint(x: 90, y: 200), margin: 6
        ))
    }

    @Test("No panel means no claim on the keyboard at all")
    func anEmptyPanelOwnsNothing() {
        // A panel built and never shown has a degenerate frame, and the margin
        // alone must not be enough to make it start swallowing keystrokes.
        #expect(!DockPreviewSelection.panelOwnsKeyboard(
            panel: .zero, pointer: .zero
        ))
    }
}
