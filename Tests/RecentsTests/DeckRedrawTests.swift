import AppKit
import Foundation
import Testing
@testable import Recents

/// The two claims the deck's redraw cost rests on.
///
/// Neither is about what the deck looks like, which is why neither is obvious
/// from reading the views. `DeckView` rebuilds its palette and re-reads its
/// icons in `body`, and `body` runs on every event of a trackpad scrub — so what
/// decides whether a scrub is smooth is whether the two of them can be
/// recognised as unchanged, not whether they are correct.
@Suite("Deck redraw")
struct DeckRedrawTests {

    // MARK: - Palette identity

    private func palette(
        appearance: DeckAppearance = .liquidGlass,
        ground: NSColor = .windowBackgroundColor,
        style: GlassStyle = .regular,
        tint: NSColor? = nil
    ) -> DeckPalette {
        DeckPalette(appearance: appearance, ground: ground, style: style, tint: tint)
    }

    @Test("A palette rebuilt from the same preferences is the same palette")
    func rebuildingFromTheSameInputsIsEqual() {
        // This is what stops every card, thumbnail and piece of glass being
        // invalidated on every frame of a scrub: SwiftUI keeps an environment
        // value's dependents only when it can see the value has not changed.
        #expect(palette() == palette())
    }

    @Test("Two grounds written the same way are the same ground, however they were built")
    func groundsCompareByColourNotByObject() {
        // The preference round-trips through a hex string, so the ground is a
        // freshly allocated `NSColor` on every read. Object identity would make
        // every rebuild look like a change.
        let a = NSColor(deckHexString: "#1E2A38")
        let b = NSColor(deckHexString: "#1E2A38")
        #expect(a != nil && b != nil)
        #expect(palette(appearance: .solid, ground: a!) == palette(appearance: .solid, ground: b!))
    }

    @Test("Every input that changes the drawing also changes the palette")
    func eachInputIsCompared() {
        // The safety half: skipping redraws is only correct while a real
        // appearance change still gets through.
        let base = palette()
        #expect(base != palette(appearance: .solid))
        #expect(base != palette(ground: .red))
        #expect(base != palette(style: .clear))
        #expect(base != palette(tint: .orange))
    }

    // MARK: - Icons

    @MainActor
    @Test("Asking twice for one file's icon hands back the same picture, not an equal one")
    func iconsAreHeld() {
        // `Image(nsImage:)` compares the object it was given. A fresh `NSImage`
        // per body pass — which is what `NSWorkspace.icon(forFile:)` returns —
        // therefore redraws the icon layer of every card on every frame, having
        // given SwiftUI no way to know it was the same icon.
        let path = "/Applications"
        #expect(DeckIcon.forFile(path) === DeckIcon.forFile(path))
    }

    @MainActor
    @Test("Different files still get different icons")
    func iconsAreKeyedByPath() {
        let folder = DeckIcon.forFile("/Applications")
        let root = DeckIcon.forFile("/")
        #expect(folder === DeckIcon.forFile("/Applications"))
        #expect(root === DeckIcon.forFile("/"))
    }
}
