import CoreGraphics
import Foundation
import Testing
@testable import Recents

/// How a Dock preview's row of thumbnails is sized.
///
/// The failure this arithmetic exists to prevent is one nobody sees until they
/// happen to have several windows open on a small display: the row is laid out
/// wider than the screen, and the placement code can only slide a panel that
/// does not fit, so the last thumbnails end up off the edge entirely.
@Suite("DockPreviewLayout")
struct DockPreviewLayoutTests {

    /// A 15-inch laptop's usable width, less the panel's keep-out margins —
    /// what `DockPreviewController` actually hands the view.
    private let laptop: CGFloat = 1496

    private func size(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        CGSize(width: width, height: height)
    }

    private func room(_ availableWidth: CGFloat) -> CGFloat {
        availableWidth - DockPreviewLayout.padding * 2
    }

    // MARK: - When there is room

    @Test("One ordinary window is drawn at the preferred height")
    func singleWindowIsUnshrunk() {
        let layout = DockPreviewLayout(sourceSizes: [size(1600, 1000)], availableWidth: laptop)
        #expect(layout.height == DockPreviewLayout.preferredHeight)
    }

    @Test("Six ordinary windows still fit a laptop screen, so nothing shrinks")
    func sixWindowsFitALaptop() {
        let layout = DockPreviewLayout(
            sourceSizes: Array(repeating: size(1600, 1000), count: 6), availableWidth: laptop
        )
        #expect(layout.height == DockPreviewLayout.preferredHeight)
        #expect(layout.rowWidth <= room(laptop))
    }

    @Test("A thumbnail's width follows its window's shape")
    func widthFollowsAspect() {
        let layout = DockPreviewLayout(
            sourceSizes: [size(1600, 1000), size(1000, 1000)], availableWidth: laptop
        )
        #expect(layout.widths[0] > layout.widths[1])
        #expect(abs(layout.widths[0] - layout.height * 1.6) < 0.001)
    }

    @Test("Every thumbnail in a row shares one height, whatever shape it is")
    func oneSharedHeight() {
        let layout = DockPreviewLayout(
            sourceSizes: [size(3440, 1440), size(400, 900), size(1600, 1000)],
            availableWidth: laptop
        )
        #expect(layout.widths.count == 3)
        #expect(layout.height > 0)
    }

    // MARK: - When there is not

    @Test("Six ultra-wide windows are shrunk until the row fits")
    func wideWindowsShrinkToFit() {
        let layout = DockPreviewLayout(
            sourceSizes: Array(repeating: size(3440, 1440), count: 6), availableWidth: laptop
        )
        #expect(layout.height < DockPreviewLayout.preferredHeight)
        #expect(layout.rowWidth <= room(laptop) + 0.001)
    }

    @Test("A row that has been shrunk fits, for every count up to the cap")
    func shrinkingAlwaysFitsWhereItCan() {
        for count in 1...6 {
            let layout = DockPreviewLayout(
                sourceSizes: Array(repeating: size(3440, 1440), count: count),
                availableWidth: laptop
            )
            #expect(layout.rowWidth <= room(laptop) + 0.001,
                    "\(count) windows overflowed at height \(layout.height)")
        }
    }

    @Test("Shrinking stops at the floor rather than reducing thumbnails to swatches")
    func shrinkingHasAFloor() {
        let layout = DockPreviewLayout(
            sourceSizes: Array(repeating: size(1600, 1000), count: 6), availableWidth: 420
        )
        #expect(layout.height == DockPreviewLayout.minimumHeight)
    }

    @Test("A row held at the floor is left too wide, for the placement code to clamp")
    func theFloorCanLeaveTheRowTooWide() {
        let layout = DockPreviewLayout(
            sourceSizes: Array(repeating: size(1600, 1000), count: 6), availableWidth: 420
        )
        #expect(layout.rowWidth > room(420))
    }

    // MARK: - Shapes at the extremes

    @Test("An ultra-wide window is capped, so one window cannot push the panel off the screen")
    func ultraWideIsCapped() {
        let layout = DockPreviewLayout(sourceSizes: [size(10_000, 400)], availableWidth: laptop)
        let cap = DockPreviewLayout.preferredHeight * DockPreviewLayout.widestAspect
        #expect(abs(layout.widths[0] - cap) < 0.001)
    }

    @Test("A tall narrow palette is floored, so it does not collapse to a sliver")
    func narrowIsFloored() {
        let layout = DockPreviewLayout(sourceSizes: [size(200, 2000)], availableWidth: laptop)
        let floor = DockPreviewLayout.preferredHeight * DockPreviewLayout.narrowestAspect
        #expect(abs(layout.widths[0] - floor) < 0.001)
    }

    @Test("A window the server reports no size for gets the fallback shape rather than none")
    func degenerateSizesUseTheFallback() {
        for bad in [size(0, 0), size(1600, 0), size(0, 1000), size(-100, -100)] {
            let layout = DockPreviewLayout(sourceSizes: [bad], availableWidth: laptop)
            let expected = DockPreviewLayout.preferredHeight * DockPreviewLayout.fallbackAspect
            #expect(abs(layout.widths[0] - expected) < 0.001, "\(bad) was not caught")
        }
    }

    // MARK: - Degenerate inputs

    @Test("A row with nothing in it has no width and does not divide by zero")
    func emptyRow() {
        let layout = DockPreviewLayout(sourceSizes: [], availableWidth: laptop)
        #expect(layout.rowWidth == 0)
        #expect(layout.widths.isEmpty)
        #expect(layout.height == DockPreviewLayout.preferredHeight)
    }

    @Test("A screen too small to have any room at all still yields a usable height")
    func noRoomAtAll() {
        for available in [CGFloat(0), 10, 28, -500] {
            let layout = DockPreviewLayout(sourceSizes: [size(1600, 1000)], availableWidth: available)
            #expect(layout.height == DockPreviewLayout.preferredHeight)
            #expect(layout.height.isFinite)
            #expect(layout.widths[0] > 0)
        }
    }

    @Test("The row width counts the gaps between thumbnails, not only the thumbnails")
    func rowWidthIncludesSpacing() {
        let layout = DockPreviewLayout(
            sourceSizes: Array(repeating: size(1600, 1000), count: 3), availableWidth: laptop
        )
        #expect(layout.rowWidth == layout.widths.reduce(0, +) + DockPreviewLayout.spacing * 2)
    }

    @Test("A single thumbnail's row is just the thumbnail — no trailing gap")
    func singleRowHasNoSpacing() {
        let layout = DockPreviewLayout(sourceSizes: [size(1600, 1000)], availableWidth: laptop)
        #expect(layout.rowWidth == layout.widths[0])
    }

    /// The header is bounded by the row's width so that a long application name
    /// truncates instead of widening the panel. A single tall narrow window
    /// clamps to 96pt, which leaves the header nothing to say the app's name in
    /// — and a one-thumbnail row is exactly the remembered-still case where the
    /// header is carrying the whole explanation.
    @Test("A row too narrow to caption is widened to leave the header some room")
    func narrowRowIsFlooredForTheHeader() {
        let layout = DockPreviewLayout(sourceSizes: [size(200, 2000)], availableWidth: laptop)
        #expect(layout.widths[0] < DockPreviewLayout.minimumRowWidth)
        #expect(layout.rowWidth == DockPreviewLayout.minimumRowWidth)
    }

    /// The floor adds room beside a narrow row; it must never claim a wide one
    /// is narrower than the pictures actually in it.
    @Test("The floor never shrinks a row that is already wider than it")
    func floorNeverShrinksARow() {
        for count in 1...6 {
            let layout = DockPreviewLayout(
                sourceSizes: Array(repeating: size(1600, 1000), count: count),
                availableWidth: laptop
            )
            #expect(layout.rowWidth >= layout.widths.reduce(0, +))
        }
    }

    @Test("Adding a window never makes the row narrower")
    func rowGrowsMonotonically() {
        var previous: CGFloat = 0
        for count in 1...6 {
            let layout = DockPreviewLayout(
                sourceSizes: Array(repeating: size(1600, 1000), count: count),
                availableWidth: laptop
            )
            #expect(layout.rowWidth >= previous)
            previous = layout.rowWidth
        }
    }
}
