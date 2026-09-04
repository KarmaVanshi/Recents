import Foundation

/// Subsequence matching for type-to-filter.
///
/// Matches the way people actually type at a launcher: "bus709" finds
/// "BUS709_OReillys_Sustainability_Presentation.pptx", and "xls" finds every
/// spreadsheet. Searches the filename, the owning app's name, and the extension,
/// so "word" narrows to Word documents even though no filename contains it.
enum FuzzyFilter {

    static func apply(_ query: String, to items: [RecentItem]) -> [RecentItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }

        let needle = trimmed.lowercased()

        // Scored rather than merely filtered: a filename hit should outrank an
        // app-name hit, or typing "pdf" would surface Preview's whole history
        // above the PDF the user is actually reaching for.
        var scored: [(item: RecentItem, score: Int, order: Int)] = []

        for (index, item) in items.enumerated() {
            guard let score = bestScore(needle: needle, item: item) else { continue }
            scored.append((item, score, index))
        }

        scored.sort { a, b in
            // Pinned items keep their privileged position even while filtering.
            if a.item.isPinned != b.item.isPinned { return a.item.isPinned }
            if a.score != b.score { return a.score > b.score }
            return a.order < b.order
        }

        return scored.map(\.item)
    }

    private static func bestScore(needle: String, item: RecentItem) -> Int? {
        var best: Int?

        let name = item.displayName.lowercased()
        if let score = score(needle: needle, haystack: name) {
            best = max(best ?? 0, score + 100)
        }

        if let app = item.appName?.lowercased(), let score = score(needle: needle, haystack: app) {
            best = max(best ?? 0, score + 20)
        }

        let ext = item.url.pathExtension.lowercased()
        if !ext.isEmpty, ext.hasPrefix(needle) {
            best = max(best ?? 0, 60)
        }

        return best
    }

    /// Returns nil when `needle` is not a subsequence of `haystack`.
    /// Higher scores mean a tighter, earlier, more word-aligned match.
    private static func score(needle: String, haystack: String) -> Int? {
        if haystack.hasPrefix(needle) { return 90 }
        if haystack.contains(needle) { return 70 }

        var score = 0
        var lastMatch: String.Index?
        var searchIndex = haystack.startIndex

        // Running off the end of the haystack needs no test of its own: the slice
        // is then empty, and the next character simply is not found in it.
        for character in needle {
            guard let found = haystack[searchIndex...].firstIndex(of: character) else {
                return nil
            }

            // Consecutive characters and matches at word boundaries are what
            // make an abbreviation feel deliberate rather than accidental.
            if let last = lastMatch, haystack.index(after: last) == found {
                score += 5
            }
            if found == haystack.startIndex || isBoundary(haystack, before: found) {
                score += 8
            }
            score += 1

            lastMatch = found
            searchIndex = haystack.index(after: found)
        }

        return score
    }

    private static func isBoundary(_ string: String, before index: String.Index) -> Bool {
        guard index > string.startIndex else { return true }
        let previous = string[string.index(before: index)]
        return previous == " " || previous == "_" || previous == "-" || previous == "."
    }
}
