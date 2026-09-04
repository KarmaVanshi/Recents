import CoreGraphics

/// Card geometry derived from the space the rail has actually been given.
///
/// The deck used to be built from fixed constants, so enlarging the window
/// bought nothing but more empty ground around the same small cards. Every
/// dimension is now one factor away from those constants, and the factor comes
/// from the area the rail has to work in.
///
/// **Height drives size; width drives how much rail you see.** Making the window
/// taller makes the cards bigger, because height is what a portrait page preview
/// is actually short of. Making it wider does not — it reveals more of the rail
/// instead, which is the thing extra width is good for. Width only ever acts as a
/// ceiling, so a window dragged wide but left short cannot grow cards it has no
/// room to show.
///
/// The factor is quantised, and that is not cosmetic. `ThumbnailCache` keys every
/// render on the exact point size asked for, so a size that tracked the window
/// continuously would mint a fresh cache entry — and a fresh QuickLook render,
/// and a fresh PNG on disk — for every pixel of a resize drag. Rounding to a step
/// means a drag crosses a handful of sizes instead of hundreds, and the sizes it
/// lands on are hit again the next time the window is that big.
struct DeckMetrics: Equatable {

    /// Portrait, sized for a page preview.
    static let baseDocument = CGSize(width: 300, height: 380)

    /// Landscape, ≈25% of a typical 1512×945 window, per the brief.
    static let baseApplication = CGSize(width: 378, height: 236)

    static let baseSpacing: CGFloat = 250
    static let baseCornerRadius: CGFloat = 14

    /// The rail's share of the default 1180×660 window, measured rather than
    /// derived — the header and footer around it are laid out, not calculated.
    /// Scale is exactly 1 here, so the deck at its default size looks precisely as
    /// it always has, and only departures from that size change anything.
    static let referenceHeight: CGFloat = 565

    /// The horizontal room a centred card and its two neighbours occupy at scale
    /// 1. This is what width is measured against — not the window's own width,
    /// which is far more generous than the rail needs and would peg the scale at
    /// 1 no matter how tall the window got.
    static let referenceWidth: CGFloat = baseDocument.width + 2 * baseSpacing

    /// Below the floor a card stops being a preview and becomes a swatch; above
    /// the ceiling one card crowds out the neighbours that give the rail its
    /// depth.
    private static let limits: ClosedRange<CGFloat> = 0.75...2.0
    private static let step: CGFloat = 0.05

    let scale: CGFloat

    init(available: CGSize) {
        let raw = min(
            available.height / Self.referenceHeight,
            available.width / Self.referenceWidth
        )
        let clamped = min(max(raw, Self.limits.lowerBound), Self.limits.upperBound)
        scale = (clamped / Self.step).rounded() * Self.step
    }

    var documentSize: CGSize {
        CGSize(
            width: Self.baseDocument.width * scale,
            height: Self.baseDocument.height * scale
        )
    }

    var applicationSize: CGSize {
        CGSize(
            width: Self.baseApplication.width * scale,
            height: Self.baseApplication.height * scale
        )
    }

    var spacing: CGFloat { Self.baseSpacing * scale }
    var cornerRadius: CGFloat { Self.baseCornerRadius * scale }

    /// Gap between a card and its caption, and the app-icon badge on the card
    /// face — both scaled so the card's furniture keeps its proportions.
    var captionGap: CGFloat { 10 * scale }
    var badgeSize: CGFloat { 26 * scale }

    /// Type grows more slowly than the cards do. A caption scaled 1:1 against a
    /// card half again as large stops reading as a label and starts reading as a
    /// heading.
    private var typeScale: CGFloat { 1 + (scale - 1) * 0.55 }
    var titleFontSize: CGFloat { 13 * typeScale }
    var subtitleFontSize: CGFloat { 11 * typeScale }
}
