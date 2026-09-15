import AppKit
import SwiftUI

/// How the deck window is grounded.
///
/// The two modes are genuinely different at the window level, not just different
/// fills painted into the same window: glass needs a transparent, non-opaque
/// window so the material has a backdrop to refract, while solid needs an opaque
/// one so AppKit can skip compositing everything behind it. Switching therefore
/// has to reach the `NSWindow`, which is why this lives outside SwiftUI.
enum DeckAppearance: String, CaseIterable, Identifiable {

    /// Apple's Liquid Glass, over a transparent window.
    case liquidGlass

    /// Opaque window filled with one colour. No backdrop, no refraction.
    case solid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .solid:       return "Solid"
        }
    }

    var summary: String {
        switch self {
        case .liquidGlass:
            return DeckGlass.isSupported
                ? "Apple's Liquid Glass — the deck refracts and reflects whatever is behind it."
                : "Frosted and translucent. Liquid Glass itself needs macOS 26 or later."
        case .solid:
            return "Opaque background. Nothing behind the window shows through."
        }
    }
}

/// Which of Apple's two Liquid Glass materials to build the deck from.
///
/// These are the same two the system uses, not invented variants: `.regular` is
/// the standard material that adapts its own contrast to whatever it is over,
/// and `.clear` is the thinner one intended for media-rich backdrops, which lets
/// far more through and correspondingly protects legibility far less.
enum GlassStyle: String, CaseIterable, Identifiable {

    case regular
    case clear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regular: return "Regular"
        case .clear:   return "Clear"
        }
    }

    var summary: String {
        switch self {
        case .regular:
            return "The standard material. Adapts its contrast to what is behind it."
        case .clear:
            return "Thinner and more transparent. Best over a busy desktop you want to see."
        }
    }

    @available(macOS 26.0, *)
    var appKitStyle: NSGlassEffectView.Style {
        switch self {
        case .regular: return .regular
        case .clear:   return .clear
        }
    }

    @available(macOS 26.0, *)
    var swiftUIGlass: Glass {
        switch self {
        case .regular: return .regular
        case .clear:   return .clear
        }
    }
}

/// Whether real Liquid Glass is available on this machine.
///
/// Kept as one predicate rather than scattering `#available` through the views,
/// so the fallback path is decided in exactly one place and the Settings copy
/// can tell the truth about which material the user is actually getting.
enum DeckGlass {
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

// MARK: - Colour plumbing

extension NSColor {

    /// `#RRGGBB`, in sRGB. Round-trips through `UserDefaults` as a plain string,
    /// which keeps the preference legible and avoids archiving an `NSColor`.
    var deckHexString: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    convenience init?(deckHexString hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Perceived brightness, 0...1. Used to decide whether the deck should draw
    /// its text light-on-dark or dark-on-light over a user-chosen colour.
    var deckLuminance: CGFloat {
        guard let srgb = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
    }

    func deckBlended(toward other: NSColor, by fraction: CGFloat) -> NSColor {
        blended(withFraction: fraction, of: other) ?? self
    }
}

// MARK: - Surfaces

/// What a given piece of glass is being used for.
///
/// Liquid Glass is not one look applied uniformly: the system varies the
/// material by the job the surface is doing, and copying that is most of what
/// makes an interface read as belonging to the OS rather than imitating it.
enum DeckSurfaceRole {
    /// A card face — the ground a preview sits on.
    case card
    /// A control the user can press. Gets the interactive material, which
    /// responds to the pointer the way system controls do.
    case control
    /// A small static chip, capsule or key hint.
    case chip
}

// MARK: - Palette

/// The concrete fills the deck paints with, derived once per redraw from the
/// current appearance preference.
///
/// In glass mode every surface is real Liquid Glass, which is what keeps cards
/// and chips reading as pieces of one material. In solid mode glass would have
/// no backdrop to refract and would cost real GPU time for nothing, so each role
/// resolves to an opaque colour derived from the ground itself — that way a
/// custom ground colour stays coherent instead of leaving system-grey chips
/// scattered over it.
struct DeckPalette {

    let appearance: DeckAppearance
    let style: GlassStyle
    let tint: Color?

    /// The window's ground colour. Meaningful in solid mode; in glass mode it is
    /// only a fallback for offscreen rendering.
    let ground: NSColor

    /// Fill for a card face, a raised surface above the ground.
    private let raised: NSColor

    /// Fill for chips, capsules and hint pills.
    private let chip: NSColor

    init(
        appearance: DeckAppearance,
        ground: NSColor,
        style: GlassStyle = .regular,
        tint: NSColor? = nil
    ) {
        self.appearance = appearance
        self.ground = ground
        self.style = style
        self.tint = tint.map(Color.init(nsColor:))

        // Raised surfaces read as raised by moving *away* from the ground's own
        // value: lighter over a dark ground, and near-white over a light one,
        // which is the same relationship the system uses for a window's controls.
        let isDark = ground.deckLuminance < 0.5
        raised = isDark
            ? ground.deckBlended(toward: .white, by: 0.14)
            : ground.deckBlended(toward: .white, by: 0.62)
        chip = isDark
            ? ground.deckBlended(toward: .white, by: 0.10)
            : ground.deckBlended(toward: .black, by: 0.07)
    }

    var isGlass: Bool { appearance == .liquidGlass }

    /// True only when the deck is drawing genuine Liquid Glass, as opposed to
    /// the pre-macOS-26 fallback that merely looks frosted.
    var isLiquidGlass: Bool { isGlass && DeckGlass.isSupported }

    /// The Liquid Glass material for a role.
    @available(macOS 26.0, *)
    func glass(for role: DeckSurfaceRole) -> Glass {
        var glass = style.swiftUIGlass
        if let tint { glass = glass.tint(tint) }
        if role == .control { glass = glass.interactive() }
        return glass
    }

    /// The opaque fill for a role, used in solid mode and on macOS 14–15.
    func solidFill(for role: DeckSurfaceRole) -> AnyShapeStyle {
        guard !isGlass else {
            // Pre-26 fallback: materials, which is the closest the older OS has.
            switch role {
            case .card, .control: return AnyShapeStyle(.regularMaterial)
            case .chip:           return AnyShapeStyle(.thinMaterial)
            }
        }
        switch role {
        case .card:            return AnyShapeStyle(Color(nsColor: raised))
        case .control, .chip:  return AnyShapeStyle(Color(nsColor: chip))
        }
    }

    /// The full-bleed layer the peek lays over the deck. Deliberately not fully
    /// opaque in either mode — the deck staying faintly visible behind it is what
    /// makes the peek read as a layer rather than a different screen.
    var peekScrim: AnyShapeStyle {
        isGlass
            ? AnyShapeStyle(.ultraThinMaterial)
            : AnyShapeStyle(Color(nsColor: ground).opacity(0.93))
    }

    /// Glass sits over whatever the user's desktop happens to be, so captions and
    /// key hints need a whisper of scrim to hold their contrast. A solid ground
    /// already guarantees it, and darkening it would just muddy the chosen colour.
    ///
    /// Clear glass lets far more of the desktop through than regular does, so it
    /// needs correspondingly more help — this is the same trade the system makes
    /// when it puts a dimming layer behind clear-glass controls over media.
    var scrimStrength: Double {
        guard isGlass else { return 0 }
        return style == .clear ? 1.7 : 1
    }

    /// Card borders need to be visible against the ground in both modes.
    var cardBorder: Color {
        isGlass ? Color.primary.opacity(0.12) : Color.primary.opacity(0.16)
    }
}

extension DeckPalette: Equatable {

    /// Compared on what the palette is derived *from*, never on the fills
    /// derived from it: `raised` and `chip` are pure functions of `ground`, so
    /// two palettes built from the same four inputs are the same palette.
    ///
    /// The conformance is load-bearing rather than tidy. `DeckView` rebuilds
    /// this in `body` and pushes it into the environment, and `body` runs on
    /// every event of a trackpad scrub — sixty to a hundred and twenty times a
    /// second. Without `==` SwiftUI has no way to tell one rebuild from the
    /// next: the palette holds `NSColor`s, `deckBlended` allocates a fresh one
    /// each time, and freshly allocated objects are what an environment value is
    /// compared by when it is not `Equatable`. Every view that reads the palette
    /// — every card, every thumbnail, every piece of glass — was therefore
    /// invalidated on every frame of a scrub, for a value that had not changed
    /// since the window opened.
    static func == (a: DeckPalette, b: DeckPalette) -> Bool {
        a.appearance == b.appearance
            && a.style == b.style
            && a.tint == b.tint
            && a.ground == b.ground
    }
}

// MARK: - Applying a surface

extension View {

    /// Puts a deck surface behind this view: real Liquid Glass where it exists,
    /// and the palette's fill everywhere else.
    ///
    /// `glassEffect` is a view modifier rather than a `ShapeStyle`, so unlike a
    /// material it cannot be smuggled through `AnyShapeStyle` and handed to
    /// `.background`. Wrapping the branch here is what keeps that awkwardness out
    /// of every call site.
    @ViewBuilder
    func deckSurface<S: Shape>(_ role: DeckSurfaceRole, in shape: S, palette: DeckPalette)
        -> some View
    {
        if palette.isLiquidGlass, #available(macOS 26.0, *) {
            glassEffect(palette.glass(for: role), in: shape)
        } else {
            background(palette.solidFill(for: role), in: shape)
        }
    }

    /// Groups nearby glass surfaces so the system can render them in one pass and
    /// blend them into each other when they come close, which is what stops a row
    /// of glass chips from reading as separate stuck-on tiles.
    @ViewBuilder
    func deckGlassGroup(spacing: CGFloat = 12, palette: DeckPalette) -> some View {
        if palette.isLiquidGlass, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// A standalone shaped surface, for the places that need a glass *layer* in a
/// stack rather than a background behind existing content.
struct DeckSurfaceLayer<S: Shape>: View {

    let role: DeckSurfaceRole
    let shape: S

    @Environment(\.deckPalette) private var palette

    init(_ role: DeckSurfaceRole, in shape: S) {
        self.role = role
        self.shape = shape
    }

    var body: some View {
        Color.clear.deckSurface(role, in: shape, palette: palette)
    }
}

// MARK: - Environment

private struct DeckPaletteKey: EnvironmentKey {
    static let defaultValue = DeckPalette(
        appearance: .liquidGlass, ground: .windowBackgroundColor
    )
}

extension EnvironmentValues {
    /// Read by every view that paints a surface, so the appearance switch reaches
    /// the whole hierarchy without threading a parameter through each card.
    var deckPalette: DeckPalette {
        get { self[DeckPaletteKey.self] }
        set { self[DeckPaletteKey.self] = newValue }
    }
}
