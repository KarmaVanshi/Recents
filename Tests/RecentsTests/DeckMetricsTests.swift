import CoreGraphics
import Foundation
import Testing
@testable import Recents

/// Card geometry. The two claims worth holding to are the ones the doc comment
/// makes: height drives size and width only ever acts as a ceiling, and the
/// scale is quantised so a resize drag does not mint a fresh thumbnail render
/// for every pixel of travel.
@Suite("DeckMetrics")
struct DeckMetricsTests {

    private let reference = CGSize(
        width: DeckMetrics.referenceWidth, height: DeckMetrics.referenceHeight
    )

    private func metrics(width: CGFloat, height: CGFloat) -> DeckMetrics {
        DeckMetrics(available: CGSize(width: width, height: height))
    }

    // MARK: - The default window

    @Test("The reference size scales by exactly one, so the default deck is untouched")
    func referenceSizeIsScaleOne() {
        #expect(DeckMetrics(available: reference).scale == 1)
    }

    @Test("At scale one the card sizes are the documented base sizes")
    func baseSizesAtScaleOne() {
        let m = DeckMetrics(available: reference)
        #expect(m.documentSize == DeckMetrics.baseDocument)
        #expect(m.applicationSize == DeckMetrics.baseApplication)
        #expect(m.spacing == DeckMetrics.baseSpacing)
        #expect(m.cornerRadius == DeckMetrics.baseCornerRadius)
    }

    // MARK: - Height drives size, width is a ceiling

    @Test("A taller window makes the cards bigger")
    func heightGrowsTheCards() {
        let tall = metrics(width: reference.width * 4, height: reference.height * 1.5)
        #expect(tall.scale > 1)
        #expect(tall.documentSize.height > DeckMetrics.baseDocument.height)
    }

    @Test("Extra width alone buys no growth — it reveals more rail instead")
    func widthAloneDoesNotGrowTheCards() {
        let wide = metrics(width: reference.width * 4, height: reference.height)
        #expect(wide.scale == 1)
    }

    @Test("A window dragged wide but left short cannot grow cards it has no room to show")
    func widthIsOnlyACeiling() {
        let short = metrics(width: reference.width * 4, height: reference.height * 0.8)
        #expect(short.scale < 1)
    }

    @Test("A narrow window caps the scale even when it is very tall")
    func narrowWindowCapsScale() {
        let narrow = metrics(width: reference.width * 0.8, height: reference.height * 3)
        #expect(narrow.scale < 1)
    }

    // MARK: - Limits

    @Test("Scale never falls below the floor, however small the window")
    func scaleHasAFloor() {
        #expect(metrics(width: 1, height: 1).scale == 0.75)
        #expect(metrics(width: 0, height: 0).scale == 0.75)
    }

    @Test("Scale never rises above the ceiling, however large the window")
    func scaleHasACeiling() {
        #expect(metrics(width: 100_000, height: 100_000).scale == 2)
    }

    @Test("A negative available size still lands on the floor rather than inverting the deck")
    func negativeSizeIsClamped() {
        #expect(metrics(width: -500, height: -500).scale == 0.75)
    }

    // MARK: - Quantisation

    @Test("Scale lands on a 0.05 step, so a resize drag reuses cached thumbnail sizes")
    func scaleIsQuantised() {
        for height in stride(from: 300.0, through: 1400.0, by: 7.0) {
            let scale = metrics(width: 100_000, height: CGFloat(height)).scale
            let steps = (scale / 0.05).rounded()
            #expect(abs(scale - steps * 0.05) < 0.0001, "scale \(scale) is off-step")
        }
    }

    @Test("A drag across a hundred pixels crosses only a handful of distinct sizes")
    func aDragCrossesFewSizes() {
        let sizes = Set(stride(from: 560.0, through: 660.0, by: 1.0).map {
            metrics(width: 100_000, height: CGFloat($0)).documentSize.width
        })
        #expect(sizes.count <= 5, "a 100pt drag produced \(sizes.count) distinct card sizes")
    }

    @Test("Two windows of the same size produce equal metrics")
    func metricsAreValueEqual() {
        #expect(DeckMetrics(available: reference) == DeckMetrics(available: reference))
    }

    // MARK: - Derived furniture

    @Test("Every derived dimension is the base times the scale")
    func derivedDimensionsFollowScale() {
        let m = metrics(width: 100_000, height: reference.height * 1.5)
        let scale = m.scale
        #expect(m.documentSize.width == DeckMetrics.baseDocument.width * scale)
        #expect(m.documentSize.height == DeckMetrics.baseDocument.height * scale)
        #expect(m.applicationSize.width == DeckMetrics.baseApplication.width * scale)
        #expect(m.spacing == DeckMetrics.baseSpacing * scale)
        #expect(m.cornerRadius == DeckMetrics.baseCornerRadius * scale)
        #expect(m.captionGap == 10 * scale)
        #expect(m.badgeSize == 26 * scale)
    }

    @Test("Documents are portrait and applications landscape at every scale")
    func cardShapesHold() {
        for height in [300.0, 565.0, 900.0, 2000.0] {
            let m = metrics(width: 100_000, height: CGFloat(height))
            #expect(m.documentSize.height > m.documentSize.width)
            #expect(m.applicationSize.width > m.applicationSize.height)
        }
    }

    @Test("Type grows more slowly than the cards, so a caption never reads as a heading")
    func typeGrowsSlowerThanCards() {
        let big = metrics(width: 100_000, height: 100_000)
        let cardGrowth = big.documentSize.height / DeckMetrics.baseDocument.height
        let titleGrowth = big.titleFontSize / 13
        #expect(titleGrowth > 1)
        #expect(titleGrowth < cardGrowth)
    }

    @Test("Type shrinks more slowly than the cards too, so a small deck stays legible")
    func typeShrinksSlowerThanCards() {
        let small = metrics(width: 1, height: 1)
        let cardShrink = small.documentSize.height / DeckMetrics.baseDocument.height
        let titleShrink = small.titleFontSize / 13
        #expect(titleShrink < 1)
        #expect(titleShrink > cardShrink)
    }

    @Test("The subtitle stays smaller than the title at every scale")
    func subtitleStaysSmaller() {
        for height in [200.0, 565.0, 1200.0] {
            let m = metrics(width: 100_000, height: CGFloat(height))
            #expect(m.subtitleFontSize < m.titleFontSize)
        }
    }
}
