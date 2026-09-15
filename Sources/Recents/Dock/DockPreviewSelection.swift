import Combine
import Foundation

/// Which thumbnail in a Dock preview is the one being acted on.
///
/// One piece of state for both hands. The pointer sets it by entering a
/// thumbnail and the arrow keys set it by stepping along the row, so there is
/// exactly one highlighted thumbnail at any moment and the two ways of choosing
/// cannot disagree — the alternative, a hover highlight beside a separate
/// keyboard highlight, gives the user two answers to "what will Return do".
///
/// It is only a highlight. It used to decide where the capture budget went as
/// well, which made the chosen thumbnail the only live one in the row; the whole
/// row is subscribed at the full rate now, so nothing about a preview changes
/// when the highlight moves except which thumbnail Return will act on.
///
/// An object rather than a value on the view, because the controller owns it and
/// the panel's SwiftUI hierarchy is rebuilt around it. A `@State` index would be
/// reset by the rebuild after a window is closed.
@MainActor
final class DockPreviewSelection: ObservableObject {

    /// The index into the row's sources, or nil when nothing is chosen — which
    /// is how every preview opens. Nothing is preselected: the panel appears
    /// under a pointer that has not aimed at anything yet, and a highlight the
    /// user did not ask for reads as a choice already made.
    @Published var index: Int?

    /// Where an arrow key moves the highlight to, or nil when there is nowhere
    /// for it to go.
    ///
    /// With nothing chosen yet, → takes the first thumbnail and ← the last, so
    /// whichever key the user reaches for gets them into the row from the end
    /// they are thinking of.
    ///
    /// After that it stops at the ends rather than wrapping. The whole row is
    /// visible at once — six thumbnails at most, side by side — so a highlight
    /// that leapt from the last back to the first would be a surprise in the one
    /// gesture the user is making to look *along* it. Wrapping earns its keep in
    /// a list you cannot see the end of, and this is the opposite of that.
    ///
    /// Kept here, as arithmetic over a count, rather than inside the controller
    /// that owns a panel and a tap and a timer: it is the part with edges worth
    /// testing — an empty row, a row of one, both ends — and none of them need a
    /// Dock to try out.
    nonisolated static func stepping(from index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return delta > 0 ? 0 : count - 1 }
        return max(0, min(count - 1, index + delta))
    }

    /// Whether a keystroke belongs to the panel rather than to the application
    /// the user is actually working in.
    ///
    /// The keys a preview answers are taken from the front application — that is
    /// the whole reason `DockPreviewKeys` is a tap and not a monitor — so the
    /// question of when to take them is the question of when the user is
    /// addressing the panel at all. "Whenever a panel is on screen" is the wrong
    /// answer and was the one in use: a preview appears after an eighth of a
    /// second resting on a Dock tile and then stays up for as long as the
    /// pointer is anywhere in the corridor between the tile and the panel, so a
    /// pointer parked near the bottom of the screen silently ate ←, →, Escape,
    /// Return and Space out of whatever the user was typing into. Nothing on
    /// screen explained where the keys had gone.
    ///
    /// The pointer being inside the panel is the evidence, and it is the only
    /// honest one available: the panel never becomes key, so it has no focus to
    /// consult. A pointer on the tile is someone looking; a pointer on the
    /// thumbnails is someone choosing between them — and moving onto them is the
    /// same motion that highlights one, so nothing has to be learned to get the
    /// keys to work.
    ///
    /// The margin lets a pointer resting on the panel's very edge still count.
    nonisolated static func panelOwnsKeyboard(
        panel: CGRect, pointer: CGPoint, margin: CGFloat = 6
    ) -> Bool {
        guard !panel.isEmpty else { return false }
        return panel.insetBy(dx: -margin, dy: -margin).contains(pointer)
    }
}
