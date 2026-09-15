import Foundation
import Testing
@testable import Recents

/// The hold on `kMDItemLastUsedDate` reads.
///
/// The claims worth pinning are the two the store depends on: a repeat within
/// the lifetime does not reach the metadata server, and one after it does. The
/// reason the second matters as much as the first is that the whole safety
/// argument for caching these — see `RecentsStore.lastUsedDate` — rests on a
/// held value eventually being re-read rather than kept for the session.
@Suite("LastUsedDates")
struct LastUsedDatesTests {

    private let file = URL(fileURLWithPath: "/none/Quarterly Report.pdf")
    private let other = URL(fileURLWithPath: "/none/Notes.txt")

    @Test("A second ask inside the lifetime does not read again")
    func repeatsAreHeld() {
        let cache = LastUsedDates(lifetime: 60)
        var reads = 0
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(cache.date(for: file) { _ in reads += 1; return stamp } == stamp)
        #expect(cache.date(for: file) { _ in reads += 1; return stamp } == stamp)
        #expect(reads == 1)
    }

    @Test("Each file is held separately")
    func filesAreHeldSeparately() {
        let cache = LastUsedDates(lifetime: 60)
        let first = Date(timeIntervalSince1970: 1)
        let second = Date(timeIntervalSince1970: 2)

        #expect(cache.date(for: file) { _ in first } == first)
        #expect(cache.date(for: other) { _ in second } == second)
        #expect(cache.date(for: file) { _ in .distantFuture } == first)
    }

    @Test("An expired value is read again rather than kept")
    func expiryReleasesTheValue() {
        // Zero lifetime: every ask is past it, which is the boundary the store's
        // safety argument needs to hold at.
        let cache = LastUsedDates(lifetime: 0)
        var reads = 0

        _ = cache.date(for: file) { _ in reads += 1; return nil }
        _ = cache.date(for: file) { _ in reads += 1; return nil }
        #expect(reads == 2)
    }

    @Test("A file with no timestamp is held too, rather than asked about forever")
    func missingTimestampsAreHeld() {
        let cache = LastUsedDates(lifetime: 60)
        var reads = 0

        #expect(cache.date(for: file) { _ in reads += 1; return nil } == nil)
        #expect(cache.date(for: file) { _ in reads += 1; return nil } == nil)
        #expect(reads == 1)
    }

    @Test("Filling past capacity sweeps what has expired instead of growing")
    func capacityIsBounded() {
        // Lifetime zero makes every existing entry expired, so the sweep at
        // capacity has something to remove and the table cannot run away.
        let cache = LastUsedDates(lifetime: 0, capacity: 4)
        for index in 0..<64 {
            _ = cache.date(for: URL(fileURLWithPath: "/none/\(index)")) { _ in nil }
        }
        #expect(cache.count <= 4)
    }
}
