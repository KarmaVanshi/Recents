import AppKit
import SwiftUI

/// The deck window's background, in either of its two modes.
///
/// On macOS 26 and later the glass mode is Apple's Liquid Glass, through
/// `NSGlassEffectView`: a material that refracts and lenses the backdrop at its
/// edges and adapts its own contrast, rather than simply blurring. On macOS 14
/// and 15 it degrades to `NSVisualEffectView` vibrancy, which is the closest
/// those releases have.
///
/// Either way the material has to be an AppKit view over a transparent window.
/// SwiftUI's `Material` blurs *within* the window, which over a transparent
/// window has nothing to sample and renders as flat grey; both of these sample
/// the desktop and whatever apps are behind it, which is what makes the deck read
/// as a pane laid over the user's work rather than a grey panel.
///
/// Solid mode is not that view with a colour painted on it. The material is
/// removed entirely — the effect view is torn down, not hidden — and the ground
/// is the window's own `backgroundColor` on an opaque window, so AppKit stops
/// compositing everything behind us and still clips and shadows the window for
/// free. What stays constant is this view: the SwiftUI hierarchy is always its
/// child, so switching modes never rebuilds the deck.
final class DeckBackgroundView: NSView {

    /// What is currently installed, so `apply` can tell a no-op from a change
    /// that needs the material rebuilt.
    private struct Installed: Equatable {
        var appearance: DeckAppearance
        var style: GlassStyle
        var tintHex: String?
    }

    private var material: NSView?
    private var installed: Installed?

    /// The deck window's corner radius.
    ///
    /// Matched to the system's own window rounding on Tahoe so the glass and the
    /// window mask describe the same shape. If the material's radius were
    /// smaller, the mask would leave bare corners; if larger, the mask would
    /// clip away the lensed edge that makes it read as glass at all.
    static let cornerRadius: CGFloat = 16

    /// Applies an appearance. Idempotent, so it is safe to call on every change.
    func apply(_ appearance: DeckAppearance, style: GlassStyle, tint: NSColor?) {
        let wanted = Installed(
            appearance: appearance, style: style, tintHex: tint?.deckHexString
        )
        guard installed != wanted else { return }
        installed = wanted

        material?.removeFromSuperview()
        material = nil

        guard appearance == .liquidGlass else { return }

        let view = Self.makeMaterial(style: style, tint: tint)
        view.translatesAutoresizingMaskIntoConstraints = false
        // Index 0: under the hosting view, which is added once at build time and
        // never re-added.
        addSubview(view, positioned: .below, relativeTo: subviews.first)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        material = view
    }

    private static func makeMaterial(style: GlassStyle, tint: NSColor?) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = style.appKitStyle
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint
            return glass
        }
        return NSVisualEffectView.deckVibrancyFallback()
    }
}

extension NSVisualEffectView {

    /// The pre-Liquid-Glass fallback: a full-bleed `.behindWindow` pane.
    ///
    /// Only reached on macOS 14 and 15. It is a different material with a
    /// different look, which is why the Settings copy says so rather than
    /// claiming the user is getting Liquid Glass on an OS that has none.
    static func deckVibrancyFallback() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // `.followsWindowActiveState` desaturates to grey the moment the user
        // clicks another app — and the deck is explicitly meant to be usable
        // alongside other windows.
        view.state = .active
        return view
    }
}
