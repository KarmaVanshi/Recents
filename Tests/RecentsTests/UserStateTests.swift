import Foundation
import Testing
@testable import Recents

/// Pins and flicks — the only state in the app that is ours rather than the
/// system's, and the only state a user can lose.
///
/// The dated-flick rule is the part that matters most: an undated flick is a
/// permanent blocklist, which is not what the gesture promises, and the bug it
/// caused (an app forgotten once staying invisible while running in front of
/// you) is invisible until someone hits it.
@Suite("UserState")
struct UserStateTests {

    private func state(in scratch: ScratchDirectory) -> UserState {
        UserState(directory: scratch.url)
    }

    private let a = URL(fileURLWithPath: "/none/a.pdf")
    private let b = URL(fileURLWithPath: "/none/b.pdf")
    private let c = URL(fileURLWithPath: "/none/c.pdf")

    // MARK: - A fresh install

    @Test("Nothing is pinned or forgotten to begin with")
    func freshStateIsEmpty() {
        let state = state(in: ScratchDirectory())
        #expect(state.isPinned(a) == false)
        #expect(state.isSuppressed(a) == false)
        #expect(state.pinnedRank(a) == nil)
        #expect(state.lastSuppressed == nil)
    }

    // MARK: - Pinning

    @Test("Pinning and unpinning are the same gesture")
    func togglePin() {
        let state = state(in: ScratchDirectory())
        state.togglePin(a)
        #expect(state.isPinned(a))
        state.togglePin(a)
        #expect(state.isPinned(a) == false)
    }

    @Test("Pin order is the order they were pinned, and it survives an unpin in the middle")
    func pinOrder() {
        let state = state(in: ScratchDirectory())
        state.togglePin(a)
        state.togglePin(b)
        state.togglePin(c)
        #expect(state.pinnedRank(a) == 0)
        #expect(state.pinnedRank(b) == 1)
        #expect(state.pinnedRank(c) == 2)

        state.togglePin(b)
        #expect(state.pinnedRank(a) == 0)
        #expect(state.pinnedRank(c) == 1)
        #expect(state.pinnedRank(b) == nil)
    }

    @Test("Re-pinning an item puts it at the back of the pinned run, not back where it was")
    func repinningGoesToTheEnd() {
        let state = state(in: ScratchDirectory())
        state.togglePin(a)
        state.togglePin(b)
        state.togglePin(a)
        state.togglePin(a)
        #expect(state.pinnedRank(b) == 0)
        #expect(state.pinnedRank(a) == 1)
    }

    @Test("Pinning something you had forgotten brings it back, rather than silently doing nothing")
    func pinningUnforgets() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        #expect(state.isSuppressed(a))
        state.togglePin(a)
        #expect(state.isSuppressed(a) == false)
        #expect(state.isPinned(a))
    }

    // MARK: - Forgetting

    @Test("A flick hides the item and is remembered as the one to undo")
    func suppress() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        #expect(state.isSuppressed(a))
        #expect(state.lastSuppressed == a)
    }

    @Test("Forgetting a pinned item drops the pin — the two cannot both be true")
    func suppressingClearsThePin() {
        let state = state(in: ScratchDirectory())
        state.togglePin(a)
        state.suppress(a)
        #expect(state.isPinned(a) == false)
        #expect(state.isSuppressed(a))
    }

    @Test("Forgetting the same item twice does not record it twice")
    func suppressIsIdempotent() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        state.suppress(a)
        state.undoSuppress()
        #expect(state.isSuppressed(a) == false)
    }

    @Test("Forgetting one item leaves the others alone")
    func suppressionIsPerItem() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        #expect(state.isSuppressed(b) == false)
    }

    // MARK: - A flick is dated

    @Test("Using an item again overrules the flick — forgetting VLC does not hide VLC forever")
    func laterUseOverrulesTheFlick() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        #expect(state.isSuppressed(a, usedAt: Date().addingTimeInterval(60)) == false)
    }

    @Test("Use from before the flick does not overrule it")
    func earlierUseDoesNotOverruleTheFlick() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        #expect(state.isSuppressed(a, usedAt: Date().addingTimeInterval(-60)))
    }

    @Test("A spent flick is dropped, not merely ignored, so stale timestamps cannot resurrect it")
    func spentFlicksArePruned() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        _ = state.isSuppressed(a, usedAt: Date().addingTimeInterval(60))
        // Asked again with no evidence at all, the flick must be gone rather
        // than standing again.
        #expect(state.isSuppressed(a) == false)
    }

    @Test("A caller with no timestamp to offer leaves the flick standing")
    func noEvidenceLeavesTheFlickStanding() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        #expect(state.isSuppressed(a, usedAt: nil))
    }

    @Test("Overruling the flick also retires the undo, which no longer has anything to restore")
    func pruningClearsTheUndo() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        _ = state.isSuppressed(a, usedAt: Date().addingTimeInterval(60))
        #expect(state.lastSuppressed == nil)
        #expect(state.undoSuppress() == nil)
    }

    // MARK: - Undo

    @Test("Undo restores the last flick and reports what it restored")
    func undo() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        #expect(state.undoSuppress() == a)
        #expect(state.isSuppressed(a) == false)
    }

    @Test("Undo only reaches the most recent flick, and only once")
    func undoIsSingleStep() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        state.suppress(b)
        #expect(state.undoSuppress() == b)
        #expect(state.undoSuppress() == nil)
        #expect(state.isSuppressed(a))
    }

    @Test("Undo with nothing to undo returns nothing rather than restoring something arbitrary")
    func undoWithNothingToUndo() {
        #expect(state(in: ScratchDirectory()).undoSuppress() == nil)
    }

    @Test("Restoring everything clears the flicks and the undo alike")
    func clearSuppressions() {
        let state = state(in: ScratchDirectory())
        state.suppress(a)
        state.suppress(b)
        state.clearSuppressions()
        #expect(state.isSuppressed(a) == false)
        #expect(state.isSuppressed(b) == false)
        #expect(state.undoSuppress() == nil)
    }

    @Test("Restoring forgotten items leaves the pins alone")
    func clearingSuppressionsKeepsPins() {
        let state = state(in: ScratchDirectory())
        state.togglePin(a)
        state.suppress(b)
        state.clearSuppressions()
        #expect(state.isPinned(a))
    }

    // MARK: - Persistence

    @Test("Pins and flicks survive a relaunch")
    func statePersists() {
        let scratch = ScratchDirectory()
        let first = state(in: scratch)
        first.togglePin(a)
        first.togglePin(b)
        first.suppress(c)

        let second = state(in: scratch)
        #expect(second.isPinned(a))
        #expect(second.pinnedRank(b) == 1)
        #expect(second.isSuppressed(c))
    }

    @Test("Undo deliberately does not survive a relaunch")
    func undoDoesNotPersist() {
        let scratch = ScratchDirectory()
        let first = state(in: scratch)
        first.suppress(a)

        let second = state(in: scratch)
        #expect(second.lastSuppressed == nil)
        #expect(second.undoSuppress() == nil)
        #expect(second.isSuppressed(a))
    }

    @Test("A missing state file is a fresh install, not a failure")
    func missingFileIsFresh() {
        #expect(state(in: ScratchDirectory()).isPinned(a) == false)
    }

    @Test("A corrupt state file is ignored rather than crashing the app on launch")
    func corruptFileIsIgnored() {
        let scratch = ScratchDirectory()
        scratch.writeFile("state.json", contents: "{ this is not json")
        let state = state(in: scratch)
        #expect(state.isPinned(a) == false)
        #expect(state.isSuppressed(a) == false)
    }

    // MARK: - Migration from the undated format

    @Test("An undated file from an earlier build is read rather than discarded")
    func legacyFileIsRead() {
        let scratch = ScratchDirectory()
        scratch.writeFile(
            "state.json",
            contents: #"{"pinned":["/none/a.pdf"],"suppressed":["/none/b.pdf"]}"#
        )
        let state = state(in: scratch)
        #expect(state.isPinned(a))
        #expect(state.isSuppressed(b))
    }

    @Test("Migrated flicks are dated at the file's own age, so they stand until the item is used again")
    func legacyFlicksAreDatedConservatively() {
        let scratch = ScratchDirectory()
        let file = scratch.writeFile(
            "state.json",
            contents: #"{"pinned":[],"suppressed":["/none/b.pdf"]}"#
        )
        let written = Date(timeIntervalSince1970: 1_600_000_000)
        try? FileManager.default.setAttributes(
            [.modificationDate: written], ofItemAtPath: file.path
        )

        let state = state(in: scratch)
        #expect(state.isSuppressed(b, usedAt: written.addingTimeInterval(-60)))
        #expect(state.isSuppressed(b, usedAt: written.addingTimeInterval(60)) == false)
    }

    @Test("A migrated file is rewritten in the dated format, so the migration happens once")
    func migrationIsWrittenBack() {
        let scratch = ScratchDirectory()
        scratch.writeFile(
            "state.json",
            contents: #"{"pinned":["/none/a.pdf"],"suppressed":["/none/b.pdf"]}"#
        )
        _ = state(in: scratch)

        let rewritten = (try? String(contentsOf: scratch.url(for: "state.json"), encoding: .utf8)) ?? ""
        #expect(rewritten.contains("\"at\""))
        #expect(rewritten.contains("\"path\""))
    }
}
