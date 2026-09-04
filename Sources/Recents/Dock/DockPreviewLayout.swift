import CoreGraphics

/// How a row of window thumbnails is sized to fit the screen it is drawn on.
///
/// Thumbnails share one height and take whatever width their window's shape
/// asks for, which is what keeps a row of differently proportioned windows
/// sitting on one baseline. The height is the variable: a preview of six
/// windows laid out at the preferred height comes to about 1550pt, which is
/// wider than the laptop screen it is being drawn on — and the placement code
/// can only *slide* a panel that does not fit, so the far thumbnails were
/// simply off the display. The row is scaled down until it fits instead.
///
/// Kept apart from the view because it is arithmetic, and because the failure it
/// exists to prevent is one nobody sees until they happen to have six windows
/// open on a small display.
struct DockPreviewLayout {

    /// Thumbnail height when the row has room for it.
    static let preferredHeight: CGFloat = 132

    /// The floor it may shrink to. Below this a thumbnail stops being a preview
    /// and becomes a swatch, so a row that still would not fit is left too wide
    /// and clamped by the placement code — a panel with its last thumbnail off
    /// the edge is a better answer than eight unreadable ones.
    static let minimumHeight: CGFloat = 84

    /// Width limits, expressed against the height so they hold at any scale. An
    /// ultra-wide window would otherwise push the panel off the screen on its
    /// own, and a narrow palette would collapse to a sliver.
    static let narrowestAspect: CGFloat = 96 / 132
    static let widestAspect: CGFloat = 248 / 132

    /// The aspect assumed for a window the server reports a degenerate size for.
    static let fallbackAspect: CGFloat = 1.6

    static let spacing: CGFloat = 12
    static let padding: CGFloat = 14

    /// The narrowest the row is allowed to report itself as.
    ///
    /// Not about the pictures — a single narrow window's thumbnail is 96pt and
    /// looks right at that — but about the header above them, which is bounded
    /// by the row's width so that a long application name truncates instead of
    /// widening the panel. At 96pt there is no room left to say which app this
    /// is, and a one-thumbnail row is exactly the remembered-still case where
    /// the header carries the whole explanation: the picture is of a window
    /// that no longer exists, and "no window open" beside the app's name is the
    /// only thing that says so.
    static let minimumRowWidth: CGFloat = 180

    /// The header row's height, and the gap between it and the thumbnails.
    ///
    /// Fixed rather than left to whatever the app's name happens to lay out at,
    /// because it is the one measurement standing between the top of the panel
    /// and the top of a picture — and anything aiming at a thumbnail from
    /// outside has to know it. `DockCloseSelfTest` used to assume the row began
    /// at the panel's own top edge, which was true until this header was added;
    /// after that the test clicked into the header for months and reported the
    /// close button as broken.
    static let headerHeight: CGFloat = 16
    static let headerGap: CGFloat = 8

    /// The two circles revealed on a selected thumbnail: their size, the space
    /// between them, and how far they are inset from the picture's corner.
    static let controlSize: CGFloat = 18
    static let controlSpacing: CGFloat = 4
    static let controlInset: CGFloat = 6

    /// The shared thumbnail height.
    let height: CGFloat

    /// Each thumbnail's width, in the order given.
    let widths: [CGFloat]

    init(sourceSizes: [CGSize], availableWidth: CGFloat) {
        let room = availableWidth - Self.padding * 2
        let gaps = Self.gaps(count: sourceSizes.count)
        let pictures = Self.picturesWidth(sourceSizes, atHeight: Self.preferredHeight)

        // Scaled against the room left *after* the gaps, not against the whole
        // row. The gaps are a constant — they are the space between thumbnails,
        // not part of any thumbnail — so folding them into the ratio scales
        // something that will not shrink, and the row comes out slightly wider
        // than the screen every time it has to be fitted at all.
        let fitted: CGFloat
        if pictures + gaps > room, pictures > 0, room - gaps > 0 {
            fitted = max(
                Self.preferredHeight * ((room - gaps) / pictures), Self.minimumHeight
            )
        } else {
            fitted = Self.preferredHeight
        }

        height = fitted
        widths = sourceSizes.map { Self.width(for: $0, height: fitted) }
    }

    /// Where a thumbnail's close button sits, measured down and right from the
    /// panel's top-left corner.
    ///
    /// The close button is the left of the two circles, so it is a whole
    /// control and a gap further in from the picture's right edge than the
    /// maximise button beside it.
    ///
    /// This exists so that a test can press the same button a user presses.
    /// Deriving it out there, from constants copied out of the view, is how the
    /// aim drifts silently every time the layout moves — and a click that lands
    /// beside a button is indistinguishable from a button that does nothing.
    func closeButtonCentre(forThumbnailAt index: Int) -> CGPoint? {
        guard widths.indices.contains(index) else { return nil }

        let preceding = widths[..<index].reduce(0, +) + Self.spacing * CGFloat(index)
        let pictureRight = Self.padding + preceding + widths[index]

        return CGPoint(
            x: pictureRight - Self.controlInset - Self.controlSize
                - Self.controlSpacing - Self.controlSize / 2,
            y: Self.padding + Self.headerHeight + Self.headerGap
                + Self.controlInset + Self.controlSize / 2
        )
    }

    /// How wide the thumbnails and the gaps between them come to, floored so the
    /// header has somewhere to live. See `minimumRowWidth`.
    ///
    /// The thumbnails stay their own size and stay leading-aligned under it, so
    /// the floor only ever adds room to the right of a very narrow row — it
    /// never stretches a picture.
    var rowWidth: CGFloat {
        guard !widths.isEmpty else { return 0 }
        return max(
            widths.reduce(0, +) + Self.gaps(count: widths.count), Self.minimumRowWidth
        )
    }

    static func width(for size: CGSize, height: CGFloat) -> CGFloat {
        let aspect = size.width > 0 && size.height > 0
            ? size.width / size.height
            : fallbackAspect
        return height * min(max(aspect, narrowestAspect), widestAspect)
    }

    /// The thumbnails alone, without the gaps between them.
    private static func picturesWidth(_ sizes: [CGSize], atHeight height: CGFloat) -> CGFloat {
        sizes.map { width(for: $0, height: height) }.reduce(0, +)
    }

    private static func gaps(count: Int) -> CGFloat {
        spacing * CGFloat(max(count - 1, 0))
    }
}
