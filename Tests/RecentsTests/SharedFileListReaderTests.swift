import Foundation
import Testing
@testable import Recents

/// The `.sfl4` decode, and the three-way verdict that decides whether the deck
/// accuses macOS of withholding Full Disk Access.
///
/// Telling "no permission" apart from "genuinely empty" is the whole reason
/// `ReadResult` has three cases: get it wrong in one direction and the deck
/// nags about a permission it already has, and in the other it silently shows
/// Spotlight's ordering while claiming to show the Apple menu's.
@Suite("SharedFileListReader")
struct SharedFileListReaderTests {

    // MARK: - Where the lists live

    @Test("Each list names the file macOS actually keeps it in")
    func listPaths() {
        #expect(SharedFileListReader.List.recentDocuments.relativePath
            == "com.apple.LSSharedFileList.RecentDocuments.sfl4")
        #expect(SharedFileListReader.List.recentApplications.relativePath
            == "com.apple.LSSharedFileList.RecentApplications.sfl4")
        #expect(SharedFileListReader.List.recentServers.relativePath
            == "com.apple.LSSharedFileList.RecentServers.sfl4")
        #expect(SharedFileListReader.List.appDocuments(bundleID: "com.apple.preview").relativePath
            == "com.apple.LSSharedFileList.ApplicationRecentDocuments/com.apple.preview.sfl4")
    }

    @Test("Every list resolves inside the shared file list container")
    func listURLsAreInTheContainer() {
        let url = SharedFileListReader.url(for: .recentApplications)
        #expect(url.path.hasPrefix(SharedFileListReader.containerURL.path))
        #expect(SharedFileListReader.appDocumentsDirectory.path
            .hasPrefix(SharedFileListReader.containerURL.path))
    }

    // MARK: - The three verdicts

    @Test("A list that is not on this machine is missing, which is not an error")
    func absentListIsMissing() {
        let scratch = ScratchDirectory()
        guard case .missing = SharedFileListReader.read(at: scratch.url(for: "nothing.sfl4")) else {
            Issue.record("expected .missing")
            return
        }
    }

    @Test("A file that exists but refuses to open is the Full Disk Access signature")
    func unreadableListIsDenied() throws {
        let scratch = ScratchDirectory()
        let file = scratch.writeFile("locked.sfl4", contents: "whatever")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        // Running as root would defeat the permission bits and make this
        // meaningless rather than failing honestly.
        try #require(getuid() != 0)

        guard case .denied = SharedFileListReader.read(at: file) else {
            Issue.record("expected .denied")
            return
        }
    }

    @Test("A file that opens but is not a keyed archive reads as empty, not as denied")
    func unparseableListIsEmpty() {
        let scratch = ScratchDirectory()
        let file = scratch.writeFile("garbage.sfl4", contents: "not an archive")
        guard case .ok(let urls) = SharedFileListReader.read(at: file) else {
            Issue.record("expected .ok")
            return
        }
        #expect(urls.isEmpty)
    }

    // MARK: - Decoding

    @Test("A real archive resolves to the files it bookmarks, in the order it lists them")
    func decodesInOrder() throws {
        let scratch = ScratchDirectory()
        let one = scratch.writeFile("one.txt")
        let two = scratch.writeFile("two.txt")
        let three = scratch.writeFile("three.txt")

        let list = scratch.url(for: "list.sfl4")
        try writeSharedFileList([three, one, two], to: list)

        guard case .ok(let urls) = SharedFileListReader.read(at: list) else {
            Issue.record("expected .ok")
            return
        }
        #expect(urls.map(\.lastPathComponent) == ["three.txt", "one.txt", "two.txt"])
    }

    @Test("An empty list reads as an empty deck rather than as a problem")
    func emptyArchive() throws {
        let scratch = ScratchDirectory()
        let list = scratch.url(for: "list.sfl4")
        try writeSharedFileList([], to: list)

        guard case .ok(let urls) = SharedFileListReader.read(at: list) else {
            Issue.record("expected .ok")
            return
        }
        #expect(urls.isEmpty)
    }

    @Test("An entry with no bookmark is skipped rather than taking the rest of the list down")
    func entriesWithoutBookmarksAreSkipped() throws {
        let scratch = ScratchDirectory()
        let file = scratch.writeFile("kept.txt")

        let items: [[String: Any]] = [
            ["Name": "no bookmark here"],
            ["Bookmark": try file.bookmarkData()],
        ]
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: ["items": items], requiringSecureCoding: false
        )
        let list = scratch.url(for: "list.sfl4")
        try data.write(to: list)

        guard case .ok(let urls) = SharedFileListReader.read(at: list) else {
            Issue.record("expected .ok")
            return
        }
        #expect(urls.map(\.lastPathComponent) == ["kept.txt"])
    }

    @Test("An archive with no items key reads as empty")
    func archiveWithoutItems() throws {
        let scratch = ScratchDirectory()
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: ["properties": ["version": 1]], requiringSecureCoding: false
        )
        let list = scratch.url(for: "list.sfl4")
        try data.write(to: list)

        guard case .ok(let urls) = SharedFileListReader.read(at: list) else {
            Issue.record("expected .ok")
            return
        }
        #expect(urls.isEmpty)
    }

    @Test("The convenience accessor turns every failure into an empty list")
    func urlsForListSwallowsFailures() {
        #expect(SharedFileListReader.urls(for: .appDocuments(bundleID: "invalid.bundle.id.\(UUID())")).isEmpty)
    }

    // MARK: - The document index

    @Test("Merging folds a second source in behind the first, never over it")
    func mergePrecedence() {
        let a = URL(fileURLWithPath: "/none/a.docx")
        var index = SharedFileListReader.DocumentIndex(
            owners: [a: "com.apple.TextEdit"],
            documentsByApp: ["com.apple.textedit": [a]]
        )
        index.merge(SharedFileListReader.DocumentIndex(
            owners: [a: "com.microsoft.Word"],
            documentsByApp: ["com.microsoft.word": [a]]
        ))

        #expect(index.owners[a] == "com.apple.TextEdit")
        #expect(index.documentsByApp["com.microsoft.word"] == [a])
    }

    @Test("Merging fills the gaps — an app the first source knows nothing about is taken whole")
    func mergeFillsGaps() {
        let a = URL(fileURLWithPath: "/none/a.docx")
        let b = URL(fileURLWithPath: "/none/b.xlsx")
        var index = SharedFileListReader.DocumentIndex(
            owners: [a: "com.apple.TextEdit"], documentsByApp: ["com.apple.textedit": [a]]
        )
        index.merge(SharedFileListReader.DocumentIndex(
            owners: [b: "com.microsoft.Excel"], documentsByApp: ["com.microsoft.excel": [b]]
        ))

        #expect(index.owners[b] == "com.microsoft.Excel")
        #expect(index.documentsByApp.count == 2)
    }

    @Test("Merging two lists for the same app appends without duplicating")
    func mergeAppendsWithoutDuplicates() {
        let a = URL(fileURLWithPath: "/none/a.docx")
        let b = URL(fileURLWithPath: "/none/b.docx")
        let c = URL(fileURLWithPath: "/none/c.docx")

        var index = SharedFileListReader.DocumentIndex(
            owners: [:], documentsByApp: ["com.microsoft.word": [a, b]]
        )
        index.merge(SharedFileListReader.DocumentIndex(
            owners: [:], documentsByApp: ["com.microsoft.word": [b, c]]
        ))

        #expect(index.documentsByApp["com.microsoft.word"] == [a, b, c])
    }

    @Test("Merging an empty index changes nothing")
    func mergingNothingIsANoOp() {
        let a = URL(fileURLWithPath: "/none/a.docx")
        var index = SharedFileListReader.DocumentIndex(
            owners: [a: "com.apple.TextEdit"], documentsByApp: ["com.apple.textedit": [a]]
        )
        let before = index.documentsByApp
        index.merge(SharedFileListReader.DocumentIndex())
        #expect(index.documentsByApp == before)
        #expect(index.owners[a] == "com.apple.TextEdit")
    }
}
