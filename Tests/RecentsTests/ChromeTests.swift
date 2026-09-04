import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Recents

/// Small pieces of presentation that are nonetheless load-bearing: the shortcut
/// as it is displayed, the colours as they round-trip through a plist, and the
/// command-line flags a build script drives the app with.
@Suite("Chrome")
struct ChromeTests {

    // MARK: - Shortcut glyphs

    @Test("Modifiers are drawn in Apple's menu order, ⌃⌥⇧⌘, whatever order they were set in")
    func modifierOrder() {
        let all = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        #expect(KeyCodeNames.modifierGlyphs(all) == "⌃⌥⇧⌘")
    }

    @Test("Only the modifiers that are held are drawn")
    func modifierSubset() {
        #expect(KeyCodeNames.modifierGlyphs(UInt32(cmdKey)) == "⌘")
        #expect(KeyCodeNames.modifierGlyphs(UInt32(cmdKey | shiftKey)) == "⇧⌘")
        #expect(KeyCodeNames.modifierGlyphs(0) == "")
    }

    @Test("AppKit's modifier flags convert to the Carbon mask RegisterEventHotKey expects")
    func carbonModifierConversion() {
        #expect(KeyCodeNames.carbonModifiers(from: [.command]) == UInt32(cmdKey))
        #expect(KeyCodeNames.carbonModifiers(from: [.shift, .command]) == UInt32(cmdKey | shiftKey))
        #expect(KeyCodeNames.carbonModifiers(from: []) == 0)
        #expect(KeyCodeNames.carbonModifiers(from: [.control, .option, .shift, .command])
            == UInt32(controlKey | optionKey | shiftKey | cmdKey))
    }

    @Test("The conversion ignores flags a hotkey cannot carry, like Caps Lock")
    func irrelevantFlagsAreIgnored() {
        #expect(KeyCodeNames.carbonModifiers(from: [.capsLock, .function, .command]) == UInt32(cmdKey))
    }

    @Test("The two conversions agree, so a recorded shortcut displays as it was pressed")
    func recordingRoundTrips() {
        let glyphs = KeyCodeNames.modifierGlyphs(
            KeyCodeNames.carbonModifiers(from: [.shift, .command]))
        #expect(glyphs == "⇧⌘")
    }

    @Test("Keys with no printable character are named rather than left blank")
    func namedKeys() {
        #expect(KeyCodeNames.keyName(UInt32(kVK_Space)) == "Space")
        #expect(KeyCodeNames.keyName(UInt32(kVK_Return)) == "↩")
        #expect(KeyCodeNames.keyName(UInt32(kVK_Escape)) == "⎋")
        #expect(KeyCodeNames.keyName(UInt32(kVK_LeftArrow)) == "←")
        #expect(KeyCodeNames.keyName(UInt32(kVK_F5)) == "F5")
    }

    @Test("A key code the layout cannot translate still produces something readable")
    func unknownKeyIsStillNamed() {
        #expect(KeyCodeNames.keyName(9999).isEmpty == false)
    }

    @Test("A full shortcut reads as one string, modifiers then key")
    func describeJoinsBoth() {
        let described = KeyCodeNames.describe(
            keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey | shiftKey))
        #expect(described == "⇧⌘Space")
    }

    // MARK: - Colours

    @Test("A colour round-trips through the hex string a preference stores")
    func hexRoundTrip() {
        for hex in ["#000000", "#FFFFFF", "#204060", "#1A2B3C"] {
            let colour = NSColor(deckHexString: hex)
            #expect(colour?.deckHexString == hex, "\(hex) did not survive the round trip")
        }
    }

    @Test("A hex string is accepted with or without its hash, and in either case")
    func hexIsForgiving() {
        #expect(NSColor(deckHexString: "204060")?.deckHexString == "#204060")
        #expect(NSColor(deckHexString: "  #204060  ")?.deckHexString == "#204060")
        #expect(NSColor(deckHexString: "#ff8800")?.deckHexString == "#FF8800")
    }

    @Test("Anything that is not six hex digits is refused rather than drawn as black")
    func malformedHexIsRefused() {
        #expect(NSColor(deckHexString: "") == nil)
        #expect(NSColor(deckHexString: "#12345") == nil)
        #expect(NSColor(deckHexString: "#1234567") == nil)
        #expect(NSColor(deckHexString: "#GGGGGG") == nil)
        #expect(NSColor(deckHexString: "rebeccapurple") == nil)
    }

    @Test("Luminance separates the grounds that need light text from the ones that need dark")
    func luminanceOrdersLightAndDark() {
        let black = NSColor(deckHexString: "#000000")!
        let white = NSColor(deckHexString: "#FFFFFF")!
        #expect(black.deckLuminance < 0.5)
        #expect(white.deckLuminance > 0.5)
    }

    @Test("Luminance is weighted for perception: green reads brighter than blue at the same value")
    func luminanceIsPerceptual() {
        let green = NSColor(deckHexString: "#00FF00")!
        let blue = NSColor(deckHexString: "#0000FF")!
        let red = NSColor(deckHexString: "#FF0000")!
        #expect(green.deckLuminance > red.deckLuminance)
        #expect(red.deckLuminance > blue.deckLuminance)
    }

    @Test("Blending all the way lands on the other colour, and not at all lands on this one")
    func blendingEndpoints() {
        let black = NSColor(deckHexString: "#000000")!
        let white = NSColor(deckHexString: "#FFFFFF")!
        #expect(black.deckBlended(toward: white, by: 0).deckHexString == "#000000")
        #expect(black.deckBlended(toward: white, by: 1).deckHexString == "#FFFFFF")
        #expect(black.deckBlended(toward: white, by: 0.5).deckLuminance > 0.3)
    }

    // MARK: - Render flags

    @Test("With no --size flag the render uses the window's own default")
    func defaultRenderSize() {
        #expect(RenderOptions.size(fromArguments: ["Recents", "--render", "out.png"])
            == RenderOptions.defaultRenderSize)
    }

    @Test("--size 1600x1000 is parsed as given")
    func parsesSize() {
        #expect(RenderOptions.size(fromArguments: ["Recents", "--size", "1600x1000"])
            == CGSize(width: 1600, height: 1000))
    }

    @Test("The separator is accepted in either case")
    func parsesUppercaseSeparator() {
        #expect(RenderOptions.size(fromArguments: ["Recents", "--size", "800X600"])
            == CGSize(width: 800, height: 600))
    }

    @Test("A --size with no value after it falls back rather than reading past the end")
    func trailingSizeFlag() {
        #expect(RenderOptions.size(fromArguments: ["Recents", "--size"])
            == RenderOptions.defaultRenderSize)
    }

    @Test("A malformed size falls back instead of rendering a blank or inverted window")
    func malformedSizeFallsBack() {
        for value in ["", "1600", "1600x", "x1000", "widexhigh", "1600x1000x900", "0x0", "-100x200"] {
            #expect(RenderOptions.size(fromArguments: ["Recents", "--size", value])
                == RenderOptions.defaultRenderSize, "\(value) was accepted")
        }
    }

    @Test("A fractional size is honoured — it is a window size, not a pixel count")
    func fractionalSizeIsAccepted() {
        #expect(RenderOptions.size(fromArguments: ["Recents", "--size", "1600.5x1000.25"])
            == CGSize(width: 1600.5, height: 1000.25))
    }

    // MARK: - Column alignment in the dump output

    @Test("A short name is padded to the column width")
    func padsShortNames() {
        #expect("abc".padded(to: 6) == "abc   ")
    }

    @Test("A name that exactly fills the column is left alone rather than losing a character to an ellipsis")
    func exactWidthIsUntouched() {
        #expect("abcdef".padded(to: 6) == "abcdef")
    }

    @Test("A name too long for the column is truncated with an ellipsis, and still fits")
    func truncatesLongNames() {
        let padded = "abcdefghij".padded(to: 6)
        #expect(padded == "abcde…")
        #expect(padded.count == 6)
    }

    @Test("Every result is exactly the column width, whatever went in")
    func everyResultIsTheColumnWidth() {
        for name in ["", "a", "abcde", "abcdef", "abcdefghijklmnop"] {
            #expect(name.padded(to: 8).count == 8, "\(name) did not fill the column")
        }
    }

    @Test("A zero-width column yields an empty string rather than trapping on a negative prefix")
    func zeroWidthColumn() {
        #expect("abc".padded(to: 0) == "")
        #expect("abc".padded(to: -1) == "")
    }
}
