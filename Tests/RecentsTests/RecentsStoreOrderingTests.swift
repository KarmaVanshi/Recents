import Foundation
import Testing
@testable import Recents

/// The two pieces of the merge that are pure enough to hold to account directly:
/// the one place in the app that invents an order rather than reproducing
/// macOS's, and the pass that decides what an application card expands into.
@Suite("RecentsStore ordering")
struct RecentsStoreOrderingTests {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/none/\(name)") }
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Ordering by recency

    @Test("Newest first")
    func newestFirst() {
        let ordered = RecentsStore.orderedByRecency([
            (url("old"), epoch),
            (url("new"), epoch.addingTimeInterval(100)),
            (url("mid"), epoch.addingTimeInterval(50)),
        ])
        #expect(ordered.map(\.lastPathComponent) == ["new", "mid", "old"])
    }

    @Test("A file macOS recorded but Spotlight never indexed sorts last rather than being dropped")
    func undatedEntriesSortLast() {
        let ordered = RecentsStore.orderedByRecency([
            (url("undated"), nil),
            (url("dated"), epoch),
        ])
        #expect(ordered.map(\.lastPathComponent) == ["dated", "undated"])
    }

    @Test("Undated entries keep the order they were given")
    func undatedEntriesAreStable() {
        let ordered = RecentsStore.orderedByRecency([
            (url("a"), nil), (url("b"), nil), (url("c"), nil),
        ])
        #expect(ordered.map(\.lastPathComponent) == ["a", "b", "c"])
    }

    @Test("Entries sharing a timestamp keep the order they were given — sorted(by:) is not stable on its own")
    func tiesAreStable() {
        let dated = (0..<12).map { (url("f\($0)"), Optional(epoch)) }
        let ordered = RecentsStore.orderedByRecency(dated)
        #expect(ordered.map(\.lastPathComponent) == (0..<12).map { "f\($0)" })
    }

    @Test("A mixture of ties and distinct dates orders by date first and by position within a tie")
    func tiesWithinAnOrdering() {
        let ordered = RecentsStore.orderedByRecency([
            (url("tie-a"), epoch),
            (url("newest"), epoch.addingTimeInterval(10)),
            (url("tie-b"), epoch),
            (url("undated"), nil),
        ])
        #expect(ordered.map(\.lastPathComponent) == ["newest", "tie-a", "tie-b", "undated"])
    }

    @Test("Ordering nothing yields nothing")
    func emptyInput() {
        #expect(RecentsStore.orderedByRecency([]).isEmpty)
    }

    @Test("Ordering preserves every entry — nothing is lost on the way through")
    func nothingIsDropped() {
        let input: [(url: URL, usedAt: Date?)] = [
            (url("a"), epoch), (url("b"), nil), (url("c"), epoch.addingTimeInterval(1)),
        ]
        #expect(Set(RecentsStore.orderedByRecency(input)) == Set(input.map(\.url)))
    }

    // MARK: - Pruning an app's documents

    @Test("Documents that no longer exist are dropped, so a sub-deck never promises a missing file")
    func missingDocumentsAreDropped() {
        let scratch = ScratchDirectory()
        let live = scratch.writeFile("live.txt")
        let gone = scratch.url(for: "gone.txt")

        var index = SharedFileListReader.DocumentIndex(
            owners: [:], documentsByApp: ["com.apple.textedit": [gone, live]]
        )
        RecentsStore.pruneToLiveDocuments(&index)

        #expect(index.documentsByApp["com.apple.textedit"] == [live])
    }

    @Test("An app left with nothing is removed, so its card offers no chevron at all")
    func appsWithNothingLeftAreRemoved() {
        let scratch = ScratchDirectory()
        var index = SharedFileListReader.DocumentIndex(
            owners: [:],
            documentsByApp: ["com.apple.textedit": [scratch.url(for: "gone.txt")]]
        )
        RecentsStore.pruneToLiveDocuments(&index)

        #expect(index.documentsByApp["com.apple.textedit"] == nil)
        #expect(index.documentsByApp.isEmpty)
    }

    @Test("A sub-deck is capped at what fits on screen at once, taking the newest from the top")
    func documentsAreCapped() {
        let scratch = ScratchDirectory()
        let files = (0..<10).map { scratch.writeFile("f\($0).txt") }

        var index = SharedFileListReader.DocumentIndex(
            owners: [:], documentsByApp: ["com.apple.textedit": files]
        )
        RecentsStore.pruneToLiveDocuments(&index)

        let kept = index.documentsByApp["com.apple.textedit"] ?? []
        #expect(kept.count == 6)
        #expect(kept == Array(files.prefix(6)))
    }

    @Test("The cap counts live documents, not list positions — dead entries do not use up a slot")
    func theCapCountsLiveDocuments() {
        let scratch = ScratchDirectory()
        var entries: [URL] = []
        for index in 0..<10 {
            entries.append(scratch.url(for: "dead\(index).txt"))
            entries.append(scratch.writeFile("live\(index).txt"))
        }

        var index = SharedFileListReader.DocumentIndex(
            owners: [:], documentsByApp: ["com.apple.textedit": entries]
        )
        RecentsStore.pruneToLiveDocuments(&index)

        let kept = index.documentsByApp["com.apple.textedit"] ?? []
        #expect(kept.count == 6)
        #expect(kept.allSatisfy { $0.lastPathComponent.hasPrefix("live") })
    }

    @Test("A URL that cannot be stat-ed is kept — it is not this pass's business")
    func nonFileURLsAreKept() {
        let remote = URL(string: "https://example.com/doc.txt")!
        var index = SharedFileListReader.DocumentIndex(
            owners: [:], documentsByApp: ["com.apple.textedit": [remote]]
        )
        RecentsStore.pruneToLiveDocuments(&index)

        #expect(index.documentsByApp["com.apple.textedit"] == [remote])
    }

    @Test("Each app is pruned on its own, and one emptied app does not take the others with it")
    func appsArePrunedIndependently() {
        let scratch = ScratchDirectory()
        let live = scratch.writeFile("live.txt")

        var index = SharedFileListReader.DocumentIndex(
            owners: [:],
            documentsByApp: [
                "com.apple.textedit": [live],
                "com.apple.preview": [scratch.url(for: "gone.pdf")],
            ]
        )
        RecentsStore.pruneToLiveDocuments(&index)

        #expect(index.documentsByApp["com.apple.textedit"] == [live])
        #expect(index.documentsByApp["com.apple.preview"] == nil)
    }

    @Test("Pruning an empty index leaves it empty rather than trapping")
    func pruningNothing() {
        var index = SharedFileListReader.DocumentIndex()
        RecentsStore.pruneToLiveDocuments(&index)
        #expect(index.documentsByApp.isEmpty)
    }

    @Test("Pruning leaves the ownership map alone — a deleted file still says who opened it")
    func pruningDoesNotTouchOwners() {
        let scratch = ScratchDirectory()
        let gone = scratch.url(for: "gone.txt")
        var index = SharedFileListReader.DocumentIndex(
            owners: [gone: "com.apple.TextEdit"],
            documentsByApp: ["com.apple.textedit": [gone]]
        )
        RecentsStore.pruneToLiveDocuments(&index)

        #expect(index.owners[gone] == "com.apple.TextEdit")
    }
}
