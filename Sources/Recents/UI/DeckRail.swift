import CoreGraphics

/// The rail's arithmetic, with no view attached.
///
/// Every position in the deck is derived rather than stored: a card's place on
/// screen is a function of its index and where the rail has been scrolled to,
/// and in circular mode that function has to wrap — the card "before" the first
/// one is the last one, and the rail keeps counting up as the user goes round
/// rather than snapping back to zero.
///
/// That wrapping is the part worth separating out. It is four lines of modular
/// arithmetic that nothing on screen announces when it goes wrong: a deck that
/// rewinds through sixty cards instead of stepping forward by one still draws
/// perfectly, it just behaves absurdly. Kept here, it can be checked directly
/// instead of by scrubbing a live window and watching.
struct DeckRail {

    /// How many cards the rail is carrying.
    let count: Int

    /// Whether the rail wraps. `DeckView` folds the "enough cards to form a
    /// ring" test into this before constructing one, so a two-card deck is
    /// never circular however the preference is set.
    let isCircular: Bool

    init(count: Int, isCircular: Bool) {
        self.count = count
        // Below three cards a ring is indistinguishable from a jitter: the same
        // two cards swap places forever.
        self.isCircular = isCircular && count > 2
    }

    var isEmpty: Bool { count == 0 }

    /// Signed distance from the centre of the rail, in card units.
    ///
    /// Measured the short way around the ring when circular, which is what
    /// makes the deck appear to have no ends.
    func delta(for index: Int, scrollPosition: CGFloat) -> CGFloat {
        let raw = CGFloat(index) - scrollPosition
        guard isCircular, count > 0 else { return raw }

        let span = CGFloat(count)
        var wrapped = raw.truncatingRemainder(dividingBy: span)
        if wrapped > span / 2 { wrapped -= span }
        if wrapped < -span / 2 { wrapped += span }
        return wrapped
    }

    /// Neighbours sit a full step out; everything beyond compresses, so a long
    /// deck stays on screen instead of marching off the edge.
    func xOffset(for delta: CGFloat, spacing: CGFloat) -> CGFloat {
        let magnitude = abs(delta)
        let sign: CGFloat = delta < 0 ? -1 : 1
        let distance = magnitude <= 1
            ? magnitude * spacing
            : spacing + (magnitude - 1) * spacing * 0.48
        return sign * distance
    }

    /// The rail position that centres `index`.
    ///
    /// In circular mode `scrollPosition` is unbounded — it keeps counting up as
    /// the user goes round the ring — so snapping it to the bare index would
    /// rewind the whole rail. After a few laps, clicking the card next to the
    /// centred one span the deck backwards through every card in the list. Pick
    /// the representation of `index` nearest to where the rail already sits.
    func railPosition(for index: Int, scrollPosition: CGFloat) -> CGFloat {
        guard isCircular, count > 0 else { return CGFloat(index) }
        let span = CGFloat(count)
        let laps = ((scrollPosition - CGFloat(index)) / span).rounded()
        return CGFloat(index) + laps * span
    }

    /// The selection `step` cards away: wrapping when circular, clamped to the
    /// ends when not.
    func index(after index: Int, step: Int) -> Int {
        guard count > 0 else { return 0 }
        guard isCircular else { return min(max(index + step, 0), count - 1) }
        return ((index + step) % count + count) % count
    }

    /// Maps a possibly out-of-range rail position onto a real item index.
    func normalizedIndex(_ raw: Int) -> Int {
        guard count > 0 else { return 0 }
        guard isCircular else { return min(max(raw, 0), count - 1) }
        return ((raw % count) + count) % count
    }

    /// Where the rail should sit after stepping the selection.
    ///
    /// Circular decks animate toward the *nearest* representation of the target
    /// rather than its bare index, so wrapping from the last card to the first
    /// slides forward by one step instead of rewinding the whole rail.
    func scrollTarget(from scrollPosition: CGFloat, movingBy step: Int, to index: Int) -> CGFloat {
        isCircular ? scrollPosition + CGFloat(step) : railPosition(for: index, scrollPosition: scrollPosition)
    }
}
