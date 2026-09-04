import Foundation
import Testing
@testable import Recents

/// Values that are written to disk and read back later, and the one list whose
/// contents decide how much of the system a destructive action reaches.
///
/// Neither of these is the sort of thing a compiler protects. A renamed enum
/// case still compiles and still works — it simply stops matching what is
/// already in the user's plist, so their chosen appearance silently reverts on
/// the next launch. And an extra entry in the cleared-lists array still
/// compiles, and quietly widens an irreversible action.
@Suite("Persisted identifiers")
struct PersistedIdentifiersTests {

    // MARK: - Raw values in the plist

    @Test("Appearance raw values are what is already written in people's preferences")
    func appearanceRawValues() {
        #expect(DeckAppearance.liquidGlass.rawValue == "liquidGlass")
        #expect(DeckAppearance.solid.rawValue == "solid")
        #expect(DeckAppearance(rawValue: "liquidGlass") == .liquidGlass)
        #expect(DeckAppearance(rawValue: "solid") == .solid)
    }

    @Test("Glass style raw values likewise")
    func glassStyleRawValues() {
        #expect(GlassStyle.regular.rawValue == "regular")
        #expect(GlassStyle.clear.rawValue == "clear")
    }

    @Test("Summon gesture raw values likewise")
    func summonGestureRawValues() {
        #expect(SummonGesture.threeFingerTap.rawValue == "threeFingerTap")
        #expect(SummonGesture.fourFingerTap.rawValue == "fourFingerTap")
        #expect(SummonGesture.fiveFingerTap.rawValue == "fiveFingerTap")
        #expect(SummonGesture.threeFingerDoubleTap.rawValue == "threeFingerDoubleTap")
        #expect(SummonGesture.fourFingerDoubleTap.rawValue == "fourFingerDoubleTap")
    }

    @Test("Every case round-trips through its raw value, so nothing in Settings is unselectable")
    func everyCaseRoundTrips() {
        for value in DeckAppearance.allCases {
            #expect(DeckAppearance(rawValue: value.rawValue) == value)
        }
        for value in GlassStyle.allCases {
            #expect(GlassStyle(rawValue: value.rawValue) == value)
        }
        for value in SummonGesture.allCases {
            #expect(SummonGesture(rawValue: value.rawValue) == value)
        }
    }

    @Test("The default summon gesture is the one that was actually measured")
    func summonGestureDefault() {
        #expect(SummonGesture.default == .threeFingerTap)
        #expect(SummonGesture.default.fingerCount == 3)
        #expect(SummonGesture.default.tapCount == 1)
    }

    // MARK: - What Clear Menu reaches

    @Test("Clear Menu empties exactly the three lists the Apple menu shows, and no more")
    func clearedListsAreTheAppleMenusOwn() {
        let paths = AppleMenuRecents.clearedLists.map(\.relativePath)
        #expect(paths == [
            "com.apple.LSSharedFileList.RecentApplications.sfl4",
            "com.apple.LSSharedFileList.RecentDocuments.sfl4",
            "com.apple.LSSharedFileList.RecentServers.sfl4",
        ])
    }

    @Test("Per-app Open Recent menus are deliberately out of reach — the real Clear Menu leaves them alone too")
    func clearMenuNeverTouchesPerAppLists() {
        let directory = SharedFileListReader.appDocumentsDirectory.path
        for list in AppleMenuRecents.clearedLists {
            #expect(SharedFileListReader.url(for: list).path.hasPrefix(directory) == false)
        }
    }
}
