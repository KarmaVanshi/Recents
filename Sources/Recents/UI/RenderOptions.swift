import Foundation

/// Development-only rendering switches, set from the command line.
enum RenderOptions {
    /// Disables 3D card tilt. Only meaningful under `--render`: the offscreen
    /// snapshot path draws through `cacheDisplay`, which cannot composite
    /// `CATransform3D` layers and places them at their untransformed origin.
    /// Without this, snapshots misrepresent a correct layout as a broken one.
    static let flattenTransforms = CommandLine.arguments.contains("--flat")

    /// True while drawing an offscreen snapshot for `--render`.
    ///
    /// That window is ordered front but never made key, and the app is not
    /// activated, so anything the live deck shows only while it is the front
    /// window — the cards' quick-action bar — would be missing from every
    /// snapshot. The snapshot is meant to be a photograph of the shipping deck,
    /// so it renders as though the deck were in front.
    static let assumesFrontmost = CommandLine.arguments.contains("--render")

    /// Window size for `--render`, as `--size 1600x1000`. Defaults to the
    /// window's own default size.
    ///
    /// This exists to photograph the deck at more than one size, which is the
    /// only way to check that `DeckMetrics` is actually scaling the cards rather
    /// than just adding empty ground around them.
    static let renderSize: CGSize = size(fromArguments: CommandLine.arguments)

    /// The window's own default size, and what any unusable `--size` falls back
    /// to.
    static let defaultRenderSize = CGSize(width: 1180, height: 660)

    /// Parses `--size 1600x1000`, separately from the process's own arguments so
    /// the parse can be tested.
    ///
    /// A size that is not a positive, finite pair is refused rather than passed
    /// through: `--size 0x0` used to produce a zero-sized window that rendered a
    /// blank PNG, which looks like a broken deck rather than a mistyped flag.
    static func size(fromArguments arguments: [String]) -> CGSize {
        guard let index = arguments.firstIndex(of: "--size"),
              arguments.count > index + 1
        else { return defaultRenderSize }

        let parts = arguments[index + 1].lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width.isFinite, height.isFinite, width > 0, height > 0
        else { return defaultRenderSize }

        return CGSize(width: width, height: height)
    }

    /// Forces an appearance for this run without touching the stored preference,
    /// so a snapshot of the other mode does not silently change what the user
    /// sees the next time they open the deck.
    ///
    ///   `--render out.png --solid`   `--render out.png --glass`
    static let appearanceOverride: DeckAppearance? = {
        if CommandLine.arguments.contains("--solid") { return .solid }
        if CommandLine.arguments.contains("--glass") { return .liquidGlass }
        return nil
    }()

    /// The appearance to draw with: the override when one was given, otherwise
    /// whatever the user has chosen.
    static var appearance: DeckAppearance {
        appearanceOverride ?? Preferences.shared.deckAppearance
    }
}
