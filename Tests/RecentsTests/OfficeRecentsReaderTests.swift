import Foundation
import Testing
@testable import Recents

/// Office's private MRU. This is reverse-engineered from an undocumented file in
/// a sandbox container, so it is both the most fragile reader in the app and the
/// one whose failure is quietest — a changed key name would simply return
/// nothing, and Word's card would go back to expanding into an empty sub-deck.
@Suite("OfficeRecentsReader")
struct OfficeRecentsReaderTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Which apps, and where

    @Test("The three apps are spelled the way they spell themselves, PowerPoint's lowercase p included")
    func bundleIDs() {
        #expect(OfficeRecentsReader.bundleIDs == [
            "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
        ])
    }

    @Test("The store sits in the app's own sandbox container")
    func storePath() {
        let url = OfficeRecentsReader.url(forBundleID: "com.microsoft.Word")
        #expect(url.path.hasSuffix(
            "Library/Containers/com.microsoft.Word/Data/Library/Preferences/"
            + "com.microsoft.Word.securebookmarks.plist"))
    }

    // MARK: - The three verdicts

    @Test("No container means Office is not installed, which is not an error")
    func absentStoreIsMissing() {
        let scratch = ScratchDirectory()
        guard case .missing = OfficeRecentsReader.read(at: scratch.url(for: "none.plist")) else {
            Issue.record("expected .missing")
            return
        }
    }

    @Test("A store that will not open is the same Full Disk Access signature as an unreadable list")
    func unreadableStoreIsDenied() throws {
        let scratch = ScratchDirectory()
        let file = scratch.writeFile("store.plist", contents: "x")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        try #require(getuid() != 0)

        guard case .denied = OfficeRecentsReader.read(at: file) else {
            Issue.record("expected .denied")
            return
        }
    }

    @Test("Only Office's own stores are listed, and only the ones actually on this machine")
    func existingStoresAreFiltered() {
        // On a machine without Office this is empty; on one with it, every entry
        // must be a real file. Either way the promise is the same.
        for url in OfficeRecentsReader.existingStoreURLs() {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: - Parsing

    @Test("Entries come back newest first — the timestamp is the only real ordering signal these files carry")
    func sortsNewestFirst() throws {
        let scratch = ScratchDirectory()
        let old = scratch.writeFile("old.docx")
        let mid = scratch.writeFile("mid.docx")
        let new = scratch.writeFile("new.docx")

        let store = scratch.url(for: "store.plist")
        try writeOfficeStore([
            (mid, epoch.addingTimeInterval(100)),
            (old, epoch),
            (new, epoch.addingTimeInterval(200)),
        ], to: store)

        guard case .ok(let entries) = OfficeRecentsReader.read(at: store) else {
            Issue.record("expected .ok")
            return
        }
        #expect(entries.map(\.url.lastPathComponent) == ["new.docx", "mid.docx", "old.docx"])
    }

    @Test("A percent-encoded name decodes to the real filename, not to one containing %20")
    func percentEncodingIsDecoded() throws {
        let scratch = ScratchDirectory()
        let file = scratch.writeFile("Quarterly Report.docx")
        let store = scratch.url(for: "store.plist")
        try writeOfficeStore([(file, epoch)], to: store)

        guard case .ok(let entries) = OfficeRecentsReader.read(at: store) else {
            Issue.record("expected .ok")
            return
        }
        #expect(entries.first?.url.lastPathComponent == "Quarterly Report.docx")
    }

    @Test("A folder is a sandbox grant, not a recent document, so it is left out")
    func foldersAreExcluded() throws {
        let scratch = ScratchDirectory()
        let folder = scratch.makeSubdirectory("Downloads")
        let file = scratch.writeFile("notes.docx")

        let store = scratch.url(for: "store.plist")
        try writeOfficeStore([
            (folder, epoch.addingTimeInterval(500)),
            (file, epoch),
        ], to: store)

        guard case .ok(let entries) = OfficeRecentsReader.read(at: store) else {
            Issue.record("expected .ok")
            return
        }
        #expect(entries.map(\.url.lastPathComponent) == ["notes.docx"])
    }

    @Test("A document that has since been deleted is still a recent document")
    func missingFilesAreKept() throws {
        let scratch = ScratchDirectory()
        let gone = scratch.url(for: "deleted.docx")
        let store = scratch.url(for: "store.plist")
        try writeOfficeStore([(gone, epoch)], to: store)

        guard case .ok(let entries) = OfficeRecentsReader.read(at: store) else {
            Issue.record("expected .ok")
            return
        }
        #expect(entries.count == 1)
    }

    @Test("An entry with no last-used date carries no ordering, so it is skipped")
    func entriesWithoutDatesAreSkipped() throws {
        let scratch = ScratchDirectory()
        let file = scratch.writeFile("undated.docx")
        let root: [String: Any] = [file.absoluteString: ["kUUIDKey": UUID().uuidString]]
        let data = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0)

        #expect(OfficeRecentsReader.entries(fromPlist: data).isEmpty)
    }

    @Test("A key that is not a file URL is skipped rather than misread as a path")
    func nonFileKeysAreSkipped() throws {
        let root: [String: Any] = [
            "https://example.com/doc.docx": ["kLastUsedDateKey": epoch],
            "not a url at all": ["kLastUsedDateKey": epoch],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0)

        #expect(OfficeRecentsReader.entries(fromPlist: data).isEmpty)
    }

    @Test("A store that is not a plist at all yields nothing rather than throwing")
    func garbageYieldsNothing() {
        #expect(OfficeRecentsReader.entries(fromPlist: Data("not a plist".utf8)).isEmpty)
    }

    @Test("An empty store yields no entries and no error")
    func emptyStore() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [String: Any](), format: .binary, options: 0)
        #expect(OfficeRecentsReader.entries(fromPlist: data).isEmpty)
    }

    @Test("A value that is not a dictionary is skipped")
    func malformedValuesAreSkipped() throws {
        let scratch = ScratchDirectory()
        let file = scratch.writeFile("a.docx")
        let root: [String: Any] = [file.absoluteString: "unexpected"]
        let data = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0)

        #expect(OfficeRecentsReader.entries(fromPlist: data).isEmpty)
    }
}
