import Foundation
import Testing
@testable import Recents

/// One deck entry: how it names itself, what it claims about its provenance, and
/// the distinction between "the same file" and "the same card".
@Suite("RecentItem")
struct RecentItemTests {

    // MARK: - Identity

    @Test("Two entries for the same file are equal however differently they are filled in")
    func equalityIsTheURL() {
        let a = makeDocument("/none/report.pdf", rank: 0, origin: .sharedFileList)
        let b = makeDocument("/none/report.pdf", rank: 99, origin: .spotlight, isPinned: true)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Identity is what the merge dedupes by: a set keeps one card per file")
    func setDedupesByURL() {
        let items = Set([
            makeDocument("/none/a.pdf", rank: 0),
            makeDocument("/none/a.pdf", rank: 1),
            makeDocument("/none/b.pdf", rank: 2),
        ])
        #expect(items.count == 2)
    }

    @Test("The item's id is its URL, which is what ForEach keys on")
    func idIsTheURL() {
        let item = makeDocument("/none/a.pdf")
        #expect(item.id == item.url)
    }

    // MARK: - Staleness

    @Test("Pinning the same file changes the card even though the two are equal")
    func pinningChangesContentButNotIdentity() {
        let unpinned = makeDocument("/none/a.pdf")
        let pinned = makeDocument("/none/a.pdf", isPinned: true)
        #expect(unpinned == pinned)
        #expect(unpinned.hasSameContent(as: pinned) == false)
    }

    @Test("A newer timestamp is a content change: the subtitle would draw differently")
    func newerTimestampIsAContentChange() {
        let then = makeDocument("/none/a.pdf", lastUsed: Date(timeIntervalSince1970: 0))
        let now = makeDocument("/none/a.pdf", lastUsed: Date(timeIntervalSince1970: 1000))
        #expect(then.hasSameContent(as: now) == false)
    }

    @Test("An unchanged entry compares as unchanged, so the cache is not defeated")
    func identicalEntriesCompareEqual() {
        let date = Date(timeIntervalSince1970: 5)
        let app = URL(fileURLWithPath: "/none/Preview.app")
        let a = makeDocument("/none/a.pdf", rank: 3, lastUsed: date, owningApp: app, origin: .both)
        let b = makeDocument("/none/a.pdf", rank: 3, lastUsed: date, owningApp: app, origin: .both)
        #expect(a.hasSameContent(as: b))
    }

    @Test("Rank, origin and owning app are all part of the card's content")
    func everyDrawnFieldCounts() {
        let preview = URL(fileURLWithPath: "/none/Preview.app")
        let base = makeDocument("/none/a.pdf", rank: 1, owningApp: preview, origin: .both)

        let differentRank = makeDocument("/none/a.pdf", rank: 2, owningApp: preview, origin: .both)
        let differentOrigin = makeDocument("/none/a.pdf", rank: 1, owningApp: preview, origin: .spotlight)
        let differentApp = makeDocument(
            "/none/a.pdf", rank: 1,
            owningApp: URL(fileURLWithPath: "/none/Word.app"), origin: .both
        )

        #expect(base.hasSameContent(as: differentRank) == false)
        #expect(base.hasSameContent(as: differentOrigin) == false)
        #expect(base.hasSameContent(as: differentApp) == false)
    }

    @Test("A document and an application at the same path are different cards")
    func kindIsPartOfTheContent() {
        #expect(makeDocument("/none/x").hasSameContent(as: makeApplication("/none/x")) == false)
    }

    // MARK: - Lists

    @Test("Two lists of the same length agree only when every entry does")
    func listComparison() {
        let before = [makeDocument("/none/a"), makeDocument("/none/b")]
        #expect(before.hasSameContent(as: before))
        #expect(before.hasSameContent(as: [makeDocument("/none/a", isPinned: true),
                                           makeDocument("/none/b")]) == false)
    }

    @Test("Lists of different lengths never agree")
    func listLengthMatters() {
        #expect([makeDocument("/none/a")].hasSameContent(as: []) == false)
        #expect([].hasSameContent(as: [makeDocument("/none/a")]) == false)
    }

    @Test("Reordering the same items is a change, because position is what the deck draws")
    func listOrderMatters() {
        let a = makeDocument("/none/a")
        let b = makeDocument("/none/b")
        #expect([a, b].hasSameContent(as: [b, a]) == false)
    }

    @Test("Two empty lists agree")
    func emptyListsAgree() {
        #expect([RecentItem]().hasSameContent(as: []))
    }

    // MARK: - Naming

    @Test("A file with no localized name falls back to its last path component")
    func documentDisplayName() {
        #expect(makeDocument("/none/Quarterly Report.pdf").displayName == "Quarterly Report.pdf")
    }

    @Test("A server names itself by share and host, not by a path component that means nothing alone")
    func serverDisplayName() {
        #expect(makeServer("smb://nas.local/Media").displayName == "Media — nas.local")
    }

    @Test("A server with no share falls back to the host alone")
    func serverWithNoShare() {
        #expect(makeServer("smb://nas.local").displayName == "nas.local")
        #expect(makeServer("smb://nas.local/").displayName == "nas.local")
    }

    @Test("A server URL with no host at all still names itself rather than showing nothing")
    func serverWithNoHost() {
        #expect(makeServer("smb:///Media").displayName.isEmpty == false)
    }

    @Test("The owning app's name comes from the bundle, extension stripped")
    func appName() {
        let item = makeDocument("/none/a.pdf", owningApp: URL(fileURLWithPath: "/none/Microsoft Word.app"))
        #expect(item.appName == "Microsoft Word")
    }

    @Test("An item with no owning app has no app name rather than an empty one")
    func missingAppName() {
        #expect(makeDocument("/none/a.pdf", owningApp: nil).appName == nil)
    }

    // MARK: - Provenance

    @Test("Only the Apple menu's own lists make an entry authoritative")
    func authoritativeOrigins() {
        #expect(makeDocument("/none/a", origin: .sharedFileList).isAppleMenuAuthoritative)
        #expect(makeDocument("/none/a", origin: .both).isAppleMenuAuthoritative)
        #expect(makeDocument("/none/a", origin: .spotlight).isAppleMenuAuthoritative == false)
        #expect(makeApplication("/none/a", origin: .runningApplication).isAppleMenuAuthoritative == false)
    }

    @Test("Only applications carry a bundle identifier")
    func bundleIDIsApplicationsOnly() {
        #expect(makeDocument("/none/a.pdf").bundleID == nil)
        #expect(makeServer("smb://nas.local/Media").bundleID == nil)
    }

    // MARK: - Existence

    @Test("A file that is not there is reported gone, and one that is there is not")
    func stillExistsTracksTheFileSystem() {
        let scratch = ScratchDirectory()
        let file = scratch.writeFile("here.txt")
        #expect(makeDocument(file.path).stillExists)
        #expect(makeDocument(scratch.url(for: "gone.txt").path).stillExists == false)
    }

    @Test("A server is exempt — an unmounted share is the normal state for one")
    func serversAreExemptFromExistence() {
        #expect(makeServer("smb://nowhere.invalid/Media").stillExists)
    }

    @Test("A directory reports itself as one, and a file does not")
    func directoryDetection() {
        let scratch = ScratchDirectory()
        let folder = scratch.makeSubdirectory("Project")
        let file = scratch.writeFile("notes.txt")
        #expect(makeDocument(folder.path).isDirectory)
        #expect(makeDocument(file.path).isDirectory == false)
    }

    @Test("A server URL is never a directory, whatever its path looks like")
    func serverIsNotADirectory() {
        #expect(makeServer("smb://nas.local/Media").isDirectory == false)
    }

    // MARK: - Subtitles

    @Test("An application with no timestamp says what it is and nothing it cannot know")
    func applicationSubtitleWithoutDate() {
        #expect(makeApplication("/none/Preview.app").subtitle == "Application")
    }

    @Test("An application with a timestamp says what it is and when")
    func applicationSubtitleWithDate() {
        let subtitle = makeApplication("/none/Preview.app", lastUsed: Date()).subtitle
        #expect(subtitle.hasPrefix("Application · "))
        #expect(subtitle.count > "Application · ".count)
    }

    @Test("A server names its protocol")
    func serverSubtitle() {
        #expect(makeServer("smb://nas.local/Media").subtitle == "Server · SMB")
    }

    @Test("A document with an app and a date joins them, and with neither says nothing")
    func documentSubtitle() {
        let app = URL(fileURLWithPath: "/none/Preview.app")
        let both = makeDocument("/none/a.pdf", lastUsed: Date(), owningApp: app).subtitle
        #expect(both.hasPrefix("Preview · "))

        #expect(makeDocument("/none/a.pdf", owningApp: app).subtitle == "Preview")
        #expect(makeDocument("/none/a.pdf").subtitle == "")
    }

    @Test("A document with a date but no known app still says when")
    func documentSubtitleWithDateOnly() {
        let subtitle = makeDocument("/none/a.pdf", lastUsed: Date()).subtitle
        #expect(subtitle.isEmpty == false)
        #expect(subtitle.contains("·") == false)
    }
}
