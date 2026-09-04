import CoreGraphics
import Foundation
import Testing
@testable import Recents

/// The rail's modular arithmetic. None of this announces itself when it breaks —
/// a deck that rewinds through sixty cards instead of stepping forward by one
/// still draws perfectly.
@Suite("DeckRail")
struct DeckRailTests {

    private let linear = DeckRail(count: 10, isCircular: false)
    private let ring = DeckRail(count: 10, isCircular: true)

    // MARK: - When the ring exists at all

    @Test("Wrapping is refused below three cards, however the preference is set")
    func ringNeedsThreeCards() {
        #expect(DeckRail(count: 0, isCircular: true).isCircular == false)
        #expect(DeckRail(count: 1, isCircular: true).isCircular == false)
        #expect(DeckRail(count: 2, isCircular: true).isCircular == false)
        #expect(DeckRail(count: 3, isCircular: true).isCircular == true)
    }

    @Test("The preference still wins when it is off")
    func preferenceOffMeansNoRing() {
        #expect(DeckRail(count: 50, isCircular: false).isCircular == false)
    }

    // MARK: - Delta

    @Test("A linear rail's delta is the plain signed distance")
    func linearDelta() {
        #expect(linear.delta(for: 3, scrollPosition: 3) == 0)
        #expect(linear.delta(for: 5, scrollPosition: 3) == 2)
        #expect(linear.delta(for: 0, scrollPosition: 3) == -3)
    }

    @Test("A linear rail does not wrap: the last card stays nine steps from the first")
    func linearDeltaDoesNotWrap() {
        #expect(linear.delta(for: 9, scrollPosition: 0) == 9)
    }

    @Test("A ring measures the short way round, so the last card sits one step before the first")
    func ringDeltaTakesTheShortWay() {
        #expect(ring.delta(for: 9, scrollPosition: 0) == -1)
        #expect(ring.delta(for: 0, scrollPosition: 9) == 1)
    }

    @Test("A ring's delta never exceeds half the deck in either direction")
    func ringDeltaIsBounded() {
        for index in 0..<10 {
            for position in stride(from: -25.0, through: 25.0, by: 0.5) {
                let delta = ring.delta(for: index, scrollPosition: CGFloat(position))
                #expect(abs(delta) <= 5.0001, "index \(index) at \(position) gave \(delta)")
            }
        }
    }

    @Test("A ring's delta survives many laps rather than drifting with the lap count")
    func ringDeltaSurvivesLaps() {
        #expect(ring.delta(for: 3, scrollPosition: 3) == 0)
        #expect(ring.delta(for: 3, scrollPosition: 103) == 0)
        #expect(ring.delta(for: 3, scrollPosition: -97) == 0)
    }

    @Test("An empty rail yields a finite delta rather than dividing by zero")
    func emptyRailDeltaIsFinite() {
        let empty = DeckRail(count: 0, isCircular: true)
        #expect(empty.delta(for: 0, scrollPosition: 0).isFinite)
    }

    // MARK: - Horizontal placement

    @Test("The centred card sits at the centre")
    func centredCardHasNoOffset() {
        #expect(linear.xOffset(for: 0, spacing: 250) == 0)
    }

    @Test("Immediate neighbours sit a full step out, symmetrically")
    func neighboursSitAFullStepOut() {
        #expect(linear.xOffset(for: 1, spacing: 250) == 250)
        #expect(linear.xOffset(for: -1, spacing: 250) == -250)
    }

    @Test("Beyond the first neighbour the rail compresses, so a long deck stays on screen")
    func distantCardsCompress() {
        let first = linear.xOffset(for: 1, spacing: 250)
        let second = linear.xOffset(for: 2, spacing: 250)
        let third = linear.xOffset(for: 3, spacing: 250)
        #expect(second - first < first)
        #expect(third - second == second - first)
    }

    @Test("Placement is monotonic: a card further out is never drawn closer in")
    func placementIsMonotonic() {
        var previous = -CGFloat.infinity
        for delta in stride(from: 0.0, through: 6.0, by: 0.25) {
            let offset = linear.xOffset(for: CGFloat(delta), spacing: 250)
            #expect(offset >= previous)
            previous = offset
        }
    }

    // MARK: - Centring an index

    @Test("A linear rail centres an index at the index itself")
    func linearRailPosition() {
        #expect(linear.railPosition(for: 4, scrollPosition: 0) == 4)
        #expect(linear.railPosition(for: 4, scrollPosition: 99) == 4)
    }

    @Test("A ring centres on the nearest representation, so clicking a neighbour does not rewind laps")
    func ringRailPositionPicksTheNearestLap() {
        // Three laps in, card 1 should be reached at 31 — not by winding back to 1.
        #expect(ring.railPosition(for: 1, scrollPosition: 30) == 31)
        #expect(ring.railPosition(for: 9, scrollPosition: 30) == 29)
    }

    @Test("Centring an index the rail is already on is a no-op")
    func ringRailPositionIsIdempotent() {
        let position = ring.railPosition(for: 6, scrollPosition: 46)
        #expect(position == 46)
        #expect(ring.railPosition(for: 6, scrollPosition: position) == position)
    }

    // MARK: - Stepping the selection

    @Test("A linear rail clamps at both ends instead of wrapping")
    func linearStepClamps() {
        #expect(linear.index(after: 0, step: -1) == 0)
        #expect(linear.index(after: 9, step: 1) == 9)
        #expect(linear.index(after: 4, step: 3) == 7)
    }

    @Test("A ring wraps in both directions")
    func ringStepWraps() {
        #expect(ring.index(after: 9, step: 1) == 0)
        #expect(ring.index(after: 0, step: -1) == 9)
    }

    @Test("A step larger than the deck still lands on a real index")
    func oversizedStepStaysInRange() {
        #expect(ring.index(after: 0, step: 25) == 5)
        #expect(ring.index(after: 0, step: -25) == 5)
        #expect(linear.index(after: 0, step: 400) == 9)
    }

    @Test("Stepping an empty rail yields zero rather than a negative index")
    func steppingAnEmptyRail() {
        let empty = DeckRail(count: 0, isCircular: false)
        #expect(empty.index(after: 0, step: 1) == 0)
        #expect(empty.index(after: 0, step: -1) == 0)
    }

    // MARK: - Where the rail lands after a step

    @Test("A ring slides one step forward when wrapping, rather than rewinding the deck")
    func wrappingSlidesForward() {
        // Sitting on the last card, stepping forward wraps the selection to 0 —
        // but the rail must move to 10, not back to 0.
        let target = ring.scrollTarget(from: 9, movingBy: 1, to: 0)
        #expect(target == 10)
    }

    @Test("A ring slides one step back when wrapping the other way")
    func wrappingBackwardsSlidesBack() {
        #expect(ring.scrollTarget(from: 0, movingBy: -1, to: 9) == -1)
    }

    @Test("A linear rail simply lands on the index it selected")
    func linearScrollTarget() {
        #expect(linear.scrollTarget(from: 3, movingBy: 1, to: 4) == 4)
        #expect(linear.scrollTarget(from: 9, movingBy: 1, to: 9) == 9)
    }

    // MARK: - Normalising a scrubbed position

    @Test("A linear rail clamps a scrubbed position to the deck")
    func linearNormalize() {
        #expect(linear.normalizedIndex(-4) == 0)
        #expect(linear.normalizedIndex(40) == 9)
        #expect(linear.normalizedIndex(5) == 5)
    }

    @Test("A ring folds a scrubbed position back onto a real index, negatives included")
    func ringNormalize() {
        #expect(ring.normalizedIndex(10) == 0)
        #expect(ring.normalizedIndex(-1) == 9)
        #expect(ring.normalizedIndex(-11) == 9)
        #expect(ring.normalizedIndex(37) == 7)
    }

    @Test("Normalising against an empty rail yields zero rather than trapping")
    func emptyNormalize() {
        let empty = DeckRail(count: 0, isCircular: true)
        #expect(empty.normalizedIndex(7) == 0)
        #expect(empty.normalizedIndex(-7) == 0)
    }

    // MARK: - The two together

    @Test("Selecting a card and centring it leaves that card at delta zero, from any lap")
    func selectingCentresTheCard() {
        for start in stride(from: -30.0, through: 30.0, by: 3.0) {
            for index in 0..<10 {
                let position = ring.railPosition(for: index, scrollPosition: CGFloat(start))
                let delta = ring.delta(for: index, scrollPosition: position)
                #expect(abs(delta) < 0.0001, "index \(index) from \(start) left delta \(delta)")
            }
        }
    }
}
