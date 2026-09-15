import AppKit

/// File and application icons, held so that asking twice hands back the same
/// picture rather than an identical new one.
///
/// `NSWorkspace.icon(forFile:)` reads as a lookup and is not one: it is a
/// LaunchServices round trip that builds a fresh `NSImage` every time, measured
/// on this machine at ~54µs a call. Card bodies ask for one icon per card, and
/// SwiftUI re-evaluates those bodies on every event of a trackpad scrub — so a
/// nine-card rail was spending about half a millisecond of every frame
/// re-fetching pictures that had not changed.
///
/// The wasted time is only half of it. Each call returned a *different* object,
/// so `Image(nsImage:)` compared unequal to the one drawn a moment earlier and
/// SwiftUI re-rendered the icon layer of every card on every frame, having been
/// given no way to know it was the same icon. Handing back one stable instance
/// is what lets that comparison succeed.
///
/// Held for the life of the process, which is the one thing this trades away: an
/// application updated in place goes on showing its old icon until Recents is
/// next launched. An icon belongs to a path and does not otherwise change, and
/// the deck is a window that opens for a few seconds at a time.
@MainActor
enum DeckIcon {

    private static var cache: [String: NSImage] = [:]

    /// Bounded, so a long session spent scrolling a large deck cannot grow this
    /// without end. Far more than the deck ever shows at once, and refilling it
    /// costs one LaunchServices call per visible card.
    private static let limit = 512

    static func forFile(_ path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        // Dropped wholesale rather than evicted one at a time: there is no
        // recency to order an eviction by that would be worth keeping, and
        // reaching this at all means the user has browsed past five hundred
        // distinct files in one session.
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        cache[path] = icon
        return icon
    }

    static func forFile(_ url: URL) -> NSImage { forFile(url.path) }
}
