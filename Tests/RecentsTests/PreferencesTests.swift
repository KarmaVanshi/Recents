import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Recents

/// The settings, and in particular the rules that keep a hand-edited plist from
/// taking the app down with it. `UInt32(_:)` traps on a negative number, and
/// this runs inside the shared instance's initialiser — so a single bad value
/// used to kill the app on every launch before it could draw anything, with no
/// way back except `defaults delete` from a terminal.
@Suite("Preferences")
struct PreferencesTests {

    /// A `UserDefaults` that never reaches the disk.
    ///
    /// This used to be a real suite — `UserDefaults(suiteName:)` under a fresh
    /// UUID, removed again in `deinit`. It gave each test its own isolated
    /// settings, and it also left one `~/Library/Preferences/RecentsTests-<UUID>.plist`
    /// behind per test on the machine of whoever ran it: several hundred had
    /// accumulated here. Removing the domain is not enough, because emptying a
    /// domain is not the same as removing it — `cfprefsd` writes the empty
    /// result straight back out — and deleting the file from `deinit` only
    /// races that write, and mostly loses.
    ///
    /// So the suite is gone rather than tidied up after. Nothing these tests
    /// check needs a file: they check that `Preferences` reads what is in the
    /// store, writes what it is told to, clamps what is out of range, and reads
    /// its own writes back. A dictionary answers all four, and it answers them
    /// without a daemon, without disk, and without anything to clean up.
    ///
    /// Only the accessors `Preferences` and these tests actually call are
    /// overridden. Anything else would fall through to the superclass and reach
    /// the real defaults, which is exactly what this exists to prevent — so if
    /// a new preference is stored some other way, its accessor belongs here.
    private final class InMemoryDefaults: UserDefaults {
        private var stored: [String: Any] = [:]
        private var registered: [String: Any] = [:]

        override func register(defaults registrationDictionary: [String: Any]) {
            registered.merge(registrationDictionary) { _, new in new }
        }

        override func object(forKey defaultName: String) -> Any? {
            stored[defaultName] ?? registered[defaultName]
        }

        override func set(_ value: Any?, forKey defaultName: String) {
            if let value {
                stored[defaultName] = value
            } else {
                stored.removeValue(forKey: defaultName)
            }
        }

        // The typed setters are separate entry points rather than sugar over the
        // one above, and the tests reach for them when they write a raw number
        // into the store to see it clamped.
        override func set(_ value: Int, forKey defaultName: String) {
            stored[defaultName] = value
        }

        override func set(_ value: Bool, forKey defaultName: String) {
            stored[defaultName] = value
        }

        override func removeObject(forKey defaultName: String) {
            stored.removeValue(forKey: defaultName)
        }

        override func string(forKey defaultName: String) -> String? {
            object(forKey: defaultName) as? String
        }

        override func bool(forKey defaultName: String) -> Bool {
            switch object(forKey: defaultName) {
            case let value as Bool: return value
            case let value as NSNumber: return value.boolValue
            default: return false
            }
        }

        override func integer(forKey defaultName: String) -> Int {
            switch object(forKey: defaultName) {
            case let value as Int: return value
            case let value as NSNumber: return value.intValue
            default: return 0
            }
        }
    }

    /// A throwaway store, so no test can rewrite the preferences of whoever
    /// runs it.
    private final class Suite {
        let defaults: UserDefaults = InMemoryDefaults()

        func preferences() -> Preferences { Preferences(defaults: defaults) }
    }

    /// One store per test. Swift Testing builds a fresh instance of this struct
    /// for every test function, so a stored property is per-test isolation.
    private let suite = Suite()

    // MARK: - Defaults

    @Test("A fresh install gets the documented defaults")
    func registeredDefaults() {
        let prefs = suite.preferences()
        #expect(prefs.hotKeyCode == UInt32(kVK_Space))
        #expect(prefs.hotKeyModifiers == UInt32(cmdKey | shiftKey))
        #expect(prefs.isCircular)
        #expect(prefs.showApplications)
        #expect(prefs.showDocuments)
        #expect(prefs.showServers)
        #expect(prefs.documentCount == Preferences.defaultDocumentCount)
        #expect(prefs.allFilesCount == Preferences.defaultAllFilesCount)
        // The main deck carries every app's recent files out of the box. A deck
        // that would not show the file you had open five minutes ago because it
        // was open in Numbers is the thing this default exists to prevent.
        #expect(prefs.showAllFiles)
        #expect(prefs.deckAppearance == .liquidGlass)
        #expect(prefs.glassStyle == .regular)
    }

    @Test("The switches that cost the user something are off until they ask")
    func consentedFeaturesAreOffByDefault() {
        let prefs = suite.preferences()
        #expect(prefs.includeFolders == false)
        #expect(prefs.dockPreviews == false)
        #expect(prefs.trackpadGesture == false)
        #expect(prefs.hasPromptedForHotKey == false)
    }

    @Test("Live previews are on by default — a paused frame of a playing video is the bug this fixes")
    func livePreviewsOnByDefault() {
        #expect(suite.preferences().livePreviews)
    }

    @Test("No colour is chosen to begin with, so the deck follows light and dark on its own")
    func coloursDefaultToTheSystem() {
        let prefs = suite.preferences()
        #expect(prefs.solidBackgroundHex == nil)
        #expect(prefs.glassTintHex == nil)
        #expect(prefs.usesSystemSolidBackground)
        #expect(prefs.glassTint == nil)
    }

    // MARK: - Surviving a bad plist

    @Test("A negative hotkey code falls back to the default instead of trapping on launch")
    func negativeHotKeyCodeIsSurvivable() {
        suite.defaults.set(-1, forKey: "hotkey.keyCode")
        suite.defaults.set(-99, forKey: "hotkey.modifiers")

        let prefs = suite.preferences()
        #expect(prefs.hotKeyCode == UInt32(kVK_Space))
        #expect(prefs.hotKeyModifiers == UInt32(cmdKey | shiftKey))
    }

    @Test("A document count written past the top of the range is clamped on the way in")
    func oversizedCountIsClampedOnLoad() {
        suite.defaults.set(9999, forKey: "deck.documentCount")
        suite.defaults.set(9999, forKey: "deck.allFilesCount")

        let prefs = suite.preferences()
        #expect(prefs.documentCount == Preferences.documentCountRange.upperBound)
        #expect(prefs.allFilesCount == Preferences.allFilesCountRange.upperBound)
    }

    @Test("A count of zero or less is clamped up to the bottom of the range")
    func undersizedCountIsClampedOnLoad() {
        suite.defaults.set(0, forKey: "deck.documentCount")
        suite.defaults.set(-5, forKey: "deck.allFilesCount")

        let prefs = suite.preferences()
        #expect(prefs.documentCount == Preferences.documentCountRange.lowerBound)
        #expect(prefs.allFilesCount == Preferences.allFilesCountRange.lowerBound)
    }

    @Test("An unrecognised appearance or glass style falls back rather than leaving the deck blank")
    func unknownEnumValuesFallBack() {
        suite.defaults.set("holographic", forKey: "deck.appearance")
        suite.defaults.set("frosted", forKey: "deck.glassStyle")
        suite.defaults.set("nonsense", forKey: "input.summonGesture")

        let prefs = suite.preferences()
        #expect(prefs.deckAppearance == .liquidGlass)
        #expect(prefs.glassStyle == .regular)
        #expect(prefs.summonGesture == SummonGesture.default)
    }

    // MARK: - Clamping on the way out

    @Test("Assigning past the top of the range clamps rather than storing the overflow")
    func assignmentClamps() {
        let prefs = suite.preferences()
        prefs.documentCount = 9999
        #expect(prefs.documentCount == Preferences.documentCountRange.upperBound)
        prefs.documentCount = -3
        #expect(prefs.documentCount == Preferences.documentCountRange.lowerBound)
    }

    // MARK: - The two document counts

    @Test("The active limit follows the source, so switching sources does not throw a choice away")
    func documentLimitFollowsTheSource() {
        let prefs = suite.preferences()
        prefs.documentCount = 7
        prefs.allFilesCount = 40

        prefs.showAllFiles = false
        #expect(prefs.documentLimit == 7)
        #expect(prefs.documentLimitRange == Preferences.documentCountRange)

        prefs.showAllFiles = true
        #expect(prefs.documentLimit == 40)
        #expect(prefs.documentLimitRange == Preferences.allFilesCountRange)
    }

    @Test("Setting the limit writes to whichever count is active, and leaves the other alone")
    func settingTheLimitWritesTheActiveCount() {
        let prefs = suite.preferences()
        prefs.showAllFiles = false
        prefs.documentLimit = 11
        #expect(prefs.documentCount == 11)
        #expect(prefs.allFilesCount == Preferences.defaultAllFilesCount)

        prefs.showAllFiles = true
        prefs.documentLimit = 60
        #expect(prefs.allFilesCount == 60)
        #expect(prefs.documentCount == 11)
    }

    @Test("An all-files count above the narrow range survives switching back and forth")
    func theWideCountIsNotClampedByTheNarrowRange() {
        let prefs = suite.preferences()
        prefs.showAllFiles = true
        prefs.documentLimit = 90
        prefs.showAllFiles = false
        prefs.showAllFiles = true
        #expect(prefs.documentLimit == 90)
    }

    // MARK: - Persistence

    @Test("Every setting survives a relaunch")
    func settingsPersist() {
        let first = suite.preferences()
        first.hotKeyCode = 49
        first.hotKeyModifiers = UInt32(controlKey | optionKey)
        first.isCircular = false
        first.showApplications = false
        first.showDocuments = false
        first.showServers = false
        first.includeFolders = true
        first.documentCount = 12
        first.showAllFiles = true
        first.allFilesCount = 44
        first.deckAppearance = .solid
        first.glassStyle = .clear
        first.livePreviews = false
        first.dockPreviews = true
        first.trackpadGesture = true
        first.hasPromptedForHotKey = true
        first.solidBackgroundHex = "#102030"
        first.glassTintHex = "#405060"

        let second = suite.preferences()
        #expect(second.hotKeyCode == 49)
        #expect(second.hotKeyModifiers == UInt32(controlKey | optionKey))
        #expect(second.isCircular == false)
        #expect(second.showApplications == false)
        #expect(second.showDocuments == false)
        #expect(second.showServers == false)
        #expect(second.includeFolders)
        #expect(second.documentCount == 12)
        #expect(second.showAllFiles)
        #expect(second.allFilesCount == 44)
        #expect(second.deckAppearance == .solid)
        #expect(second.glassStyle == .clear)
        #expect(second.livePreviews == false)
        #expect(second.dockPreviews)
        #expect(second.trackpadGesture)
        #expect(second.hasPromptedForHotKey)
        #expect(second.solidBackgroundHex == "#102030")
        #expect(second.glassTintHex == "#405060")
    }

    @Test("Clearing a chosen colour removes it rather than storing an empty one")
    func clearingAColourRemovesIt() {
        let first = suite.preferences()
        first.solidBackgroundHex = "#102030"
        first.solidBackgroundHex = nil
        first.glassTintHex = "#405060"
        first.glassTintHex = nil

        #expect(suite.defaults.string(forKey: "deck.solidBackground") == nil)
        #expect(suite.defaults.string(forKey: "deck.glassTint") == nil)
        #expect(suite.preferences().usesSystemSolidBackground)
    }

    @Test("A chosen colour is resolved back to the colour that was chosen")
    func chosenColourResolves() {
        let prefs = suite.preferences()
        prefs.solidBackgroundHex = "#204060"
        #expect(prefs.resolvedSolidBackground.deckHexString == "#204060")
        #expect(prefs.usesSystemSolidBackground == false)
    }

    @Test("A malformed colour falls back to the system ground instead of drawing nothing")
    func malformedColourFallsBack() {
        let prefs = suite.preferences()
        prefs.solidBackgroundHex = "not a colour"
        #expect(prefs.resolvedSolidBackground == .windowBackgroundColor)
        #expect(prefs.glassTint == nil)
    }

    // MARK: - The shortcut, as displayed

    @Test("The default shortcut reads the way it does in a menu")
    func hotKeyDisplay() {
        #expect(suite.preferences().hotKeyDisplay == "⇧⌘Space")
    }
}
