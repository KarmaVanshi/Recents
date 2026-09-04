import Foundation
import Testing
@testable import Recents

/// The filter is the only thing standing between a sixty-card deck and the one
/// file the user is reaching for, and its behaviour is entirely a matter of
/// relative scores — which is exactly the kind of thing that degrades silently.
@Suite("FuzzyFilter")
struct FuzzyFilterTests {

    private let preview = URL(fileURLWithPath: "/none/Preview.app")
    private let word = URL(fileURLWithPath: "/none/Microsoft Word.app")

    // MARK: - Passing everything through

    @Test("An empty query returns the deck untouched, in order")
    func emptyQueryIsIdentity() {
        let items = [makeDocument("/none/a.pdf"), makeDocument("/none/b.pdf")]
        #expect(FuzzyFilter.apply("", to: items).map(\.url) == items.map(\.url))
    }

    @Test("A query of only whitespace is treated as empty, not as a space to match")
    func whitespaceQueryIsIdentity() {
        let items = [makeDocument("/none/a.pdf"), makeDocument("/none/b.pdf")]
        #expect(FuzzyFilter.apply("   ", to: items).count == 2)
    }

    @Test("Filtering an empty deck yields an empty deck rather than trapping")
    func emptyDeck() {
        #expect(FuzzyFilter.apply("anything", to: []).isEmpty)
    }

    // MARK: - Matching

    @Test("Matching is case-insensitive in both directions")
    func caseInsensitive() {
        let items = [makeDocument("/none/Report.pdf")]
        #expect(FuzzyFilter.apply("REPORT", to: items).count == 1)
        #expect(FuzzyFilter.apply("report", to: items).count == 1)
    }

    @Test("A non-contiguous subsequence matches — 'bus709' finds the long name")
    func subsequenceMatches() {
        let items = [makeDocument("/none/BUS709_OReillys_Sustainability.pptx")]
        #expect(FuzzyFilter.apply("bus709", to: items).count == 1)
        #expect(FuzzyFilter.apply("bussus", to: items).count == 1)
    }

    @Test("Characters in the wrong order do not match")
    func orderMatters() {
        let items = [makeDocument("/none/abc.pdf")]
        #expect(FuzzyFilter.apply("cba", to: items).isEmpty)
    }

    @Test("A character the name does not contain rejects the item")
    func absentCharacterRejects() {
        let items = [makeDocument("/none/report.pdf")]
        #expect(FuzzyFilter.apply("reportz", to: items).isEmpty)
    }

    @Test("A needle longer than the name is rejected rather than partially matched")
    func longerNeedleRejects() {
        let items = [makeDocument("/none/ab.pdf")]
        #expect(FuzzyFilter.apply("abcdefghijk", to: items).isEmpty)
    }

    @Test("A repeated character needs a second occurrence to match")
    func repeatedCharacterNeedsTwoOccurrences() {
        #expect(FuzzyFilter.apply("aa", to: [makeDocument("/none/xa")]).isEmpty)
        #expect(FuzzyFilter.apply("aa", to: [makeDocument("/none/aa")]).count == 1)
    }

    // MARK: - The app name and the extension

    @Test("The owning app's name matches even though no filename contains it")
    func matchesOwningAppName() {
        let items = [makeDocument("/none/notes.docx", owningApp: word)]
        let matched = FuzzyFilter.apply("word", to: items)
        #expect(matched.count == 1)
    }

    @Test("An extension prefix matches — 'xls' finds every spreadsheet")
    func matchesExtension() {
        let items = [
            makeDocument("/none/budget.xlsx"),
            makeDocument("/none/notes.txt"),
        ]
        let matched = FuzzyFilter.apply("xls", to: items)
        #expect(matched.map(\.url.lastPathComponent) == ["budget.xlsx"])
    }

    @Test("An item with no owning app is not rejected outright")
    func missingAppNameIsTolerated() {
        let items = [makeDocument("/none/report.pdf", owningApp: nil)]
        #expect(FuzzyFilter.apply("report", to: items).count == 1)
    }

    // MARK: - Ranking

    @Test("A filename hit outranks an app-name hit — typing 'pdf' finds the PDF, not Preview's history")
    func filenameOutranksAppName() {
        let items = [
            makeDocument("/none/minutes.txt", owningApp: URL(fileURLWithPath: "/none/PDF Expert.app")),
            makeDocument("/none/pdf-guide.txt", owningApp: preview),
        ]
        let matched = FuzzyFilter.apply("pdf", to: items)
        #expect(matched.first?.url.lastPathComponent == "pdf-guide.txt")
    }

    @Test("A prefix match outranks a mid-name match")
    func prefixOutranksContains() {
        let items = [
            makeDocument("/none/my-report.pdf"),
            makeDocument("/none/report-final.pdf"),
        ]
        let matched = FuzzyFilter.apply("report", to: items)
        #expect(matched.first?.url.lastPathComponent == "report-final.pdf")
    }

    @Test("A contiguous match outranks a scattered subsequence")
    func contiguousOutranksScattered() {
        let items = [
            makeDocument("/none/r-e-p-o-r-t.txt"),
            makeDocument("/none/quarterly report.txt"),
        ]
        let matched = FuzzyFilter.apply("report", to: items)
        #expect(matched.first?.url.lastPathComponent == "quarterly report.txt")
    }

    @Test("Equal scores keep the deck's own order, so the filter never reshuffles ties")
    func tiesAreStable() {
        let items = (0..<8).map { makeDocument("/none/report-\($0).pdf", rank: $0) }
        let matched = FuzzyFilter.apply("report", to: items)
        #expect(matched.map(\.rank) == Array(0..<8))
    }

    // MARK: - Pinning

    @Test("Pinned items hold the front of the deck even while filtering")
    func pinnedItemsLead() {
        let items = [
            makeDocument("/none/report.pdf", rank: 0),
            makeDocument("/none/a-report-appendix.pdf", rank: 1, isPinned: true),
        ]
        let matched = FuzzyFilter.apply("report", to: items)
        #expect(matched.first?.isPinned == true)
    }

    @Test("A pinned item that does not match is still filtered out")
    func pinningDoesNotBypassTheFilter() {
        let items = [
            makeDocument("/none/report.pdf", rank: 0),
            makeDocument("/none/unrelated.txt", rank: 1, isPinned: true),
        ]
        let matched = FuzzyFilter.apply("report", to: items)
        #expect(matched.map(\.url.lastPathComponent) == ["report.pdf"])
    }

    @Test("Two pinned matches keep their pinned order relative to each other")
    func pinnedItemsKeepTheirOrder() {
        let items = [
            makeDocument("/none/report-one.pdf", rank: 0, isPinned: true),
            makeDocument("/none/report-two.pdf", rank: 1, isPinned: true),
            makeDocument("/none/report-three.pdf", rank: 2),
        ]
        let matched = FuzzyFilter.apply("report", to: items)
        #expect(matched.prefix(2).map(\.rank) == [0, 1])
    }
}
