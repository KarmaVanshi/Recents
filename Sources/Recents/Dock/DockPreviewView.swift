import AppKit
import SwiftUI

/// The row of window thumbnails shown above a hovered Dock tile.
///
/// One thumbnail per window the tile stands for, each captioned with that
/// window's own title, and each of them live — including the minimized ones,
/// which is the point. macOS shows a static Exposé grid for a Dock tile only
/// after a click-and-hold; Windows has shown a moving thumbnail on plain hover
/// since Vista, and a video playing in a minimized window keeps playing in it.
/// That is the behaviour this reproduces, and it draws from the same
/// `LiveWindowPreview` engine the deck's cards do, so a window looks the same
/// in both places.
///
/// A running app with every window closed falls back to the last frame Recents
/// ever saw of it. That still is labelled with what a click on it will do rather
/// than passed off as live, because it cannot lead back to the window it shows:
/// at best it reopens the document in the picture, and otherwise the app simply
/// starts a new window. An app that is not running gets no panel at all — see
/// `DockWindows`.
///
/// The panel opens over the spot the Dock's own tooltip would have used, so it
/// carries the app's name in a header the way that tooltip did. Anything else it
/// says about state — minimized, remembered, six of eleven — is said *beside*
/// the picture rather than on top of it: a preview exists to be looked at, and
/// the labels used to sit exactly over a window's title bar and tab strip, which
/// is the part of a screenshot people actually read.
///
/// The panel never takes keyboard focus, so it has no chrome of its own: no
/// close button on the panel, no title bar, nothing to aim at but the thumbnails
/// themselves. It still answers the arrow keys, which is a different thing —
/// ←/→ walk the highlight along the row and Return acts on it, read from an
/// event tap that lives exactly as long as the panel does. See
/// `DockPreviewKeys`, and `DockPreviewSelection` for why the pointer and the
/// keyboard share one highlight rather than lighting up two thumbnails.
///
/// Note the deliberate absence of a `GlassEffectContainer` around this row.
/// Grouping glass surfaces makes the system render them in one pass, which is
/// right for a row of chips that should blend into each other — and wrong here,
/// because a thumbnail's card *is* one of those surfaces and the window image
/// sits on top of it. Grouped, the image was composited underneath the glass and
/// came out blurred to nothing: a panel with captions, badges, and no picture.
struct DockPreviewView: View {

    let target: DockWindows.Target
    /// The engine's slot for each window, vended by the controller that built
    /// this view.
    ///
    /// Handed in rather than looked up here, because vending a slot mutates the
    /// engine's table and a view is not a place to do that — and because the
    /// panel's lifetime, not a thumbnail's appearance, is what the subscription
    /// has to be tied to. See `DockPreviewController.show`.
    let slots: [CGWindowID: LiveWindowPreview.Slot]
    /// Which thumbnail is highlighted, set by the pointer and by the arrow keys
    /// alike. Owned by the controller — see `DockPreviewSelection`.
    @ObservedObject var selection: DockPreviewSelection
    /// How the row is sized, built by the controller from the width the panel's
    /// screen allows.
    ///
    /// Handed in rather than derived here, so there is one of it. The row used
    /// to be laid out at a fixed thumbnail height whatever it contained, so six
    /// windows came to about 1550pt — wider than the laptop screen it was being
    /// drawn on, and the placement code can only slide a panel that does not
    /// fit, not shrink it. The far thumbnails were simply off the display. Now
    /// that the fitted result also decides where a thumbnail's buttons land,
    /// computing it twice would be two answers to the same question.
    let layout: DockPreviewLayout
    /// The owning app's icon, used in the header and as the placeholder inside a
    /// thumbnail that has not received its first frame yet.
    ///
    /// Handed in rather than looked up here. As a computed property it was read
    /// once for the header and again for every thumbnail, on every pass of this
    /// body — and the body is re-evaluated whenever the highlight moves, so
    /// running the pointer along a row of six windows was fourteen
    /// `NSWorkspace.icon(forFile:)` calls per thumbnail crossed.
    let icon: NSImage?
    /// Called when a thumbnail is clicked. Every one of these reports back
    /// whether the window was actually acted on, because all three fail the same
    /// silent way — the window cannot be reached through Accessibility, or its
    /// title-bar button will not answer — and the thumbnail is the only place
    /// left to say so. See `DockWindows.ActionOutcome`.
    let onActivate: (WindowServerCapture.WindowRef) -> Bool
    let onClose: (WindowServerCapture.WindowRef) -> Bool
    let onZoom: (WindowServerCapture.WindowRef) -> Bool
    /// Clicking a remembered still, which has no window to act on: reopen the
    /// document it shows, or failing that the app. See `DockWindows.open`.
    let onOpen: () -> Void
    /// A thumbnail gaining or losing the pointer, by position in the row. The
    /// controller turns that into the selection — the highlight, and what Return
    /// acts on. It does not change how often anything is captured: every
    /// thumbnail in the row is live whether the pointer is on it or not.
    let onHover: (Int, Bool) -> Void

    /// Built here rather than inherited, because this view is the root of its
    /// own hosting view in a panel of its own — there is no deck above it to
    /// have put a palette in the environment. It is then pushed down so the
    /// thumbnails and their chips paint from the same source, exactly as the
    /// deck does.
    private var palette: DeckPalette {
        let prefs = Preferences.shared
        return DeckPalette(
            appearance: RenderOptions.appearance,
            ground: prefs.resolvedSolidBackground,
            style: prefs.glassStyle,
            tint: prefs.glassTint
        )
    }

    // MARK: - Metrics

    /// The sources this panel is drawing, in the order they are drawn.
    private var sources: [DockThumbnail.Source] { Self.sources(for: target) }

    private static func sources(for target: DockWindows.Target) -> [DockThumbnail.Source] {
        if target.windows.isEmpty, let still = target.still {
            return [.remembered(still, target.document)]
        }
        return target.windows.map { .window($0) }
    }

    /// The shapes the row will be laid out from, in order, so the controller can
    /// build the layout before there is a view to ask.
    static func sourceSizes(for target: DockWindows.Target) -> [CGSize] {
        sources(for: target).map(\.size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DockPreviewLayout.headerGap) {
            header
                // Bounded by the row it labels, so a long application name
                // widens nothing — it truncates instead. Its height is fixed
                // too: it is what separates the top of the panel from the top of
                // a picture, and `DockPreviewLayout` has to be able to say where
                // that is.
                .frame(
                    width: layout.rowWidth,
                    height: DockPreviewLayout.headerHeight,
                    alignment: .leading
                )

            HStack(alignment: .top, spacing: DockPreviewLayout.spacing) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                    DockThumbnail(
                        source: source,
                        slot: source.windowID.flatMap { slots[$0] },
                        isSelected: selection.index == index,
                        width: layout.widths[index],
                        height: layout.height,
                        icon: icon,
                        fallbackTitle: target.name,
                        onActivate: {
                            guard let window = source.window else {
                                // A remembered still has no window to fail to
                                // reach: opening a document is the app's job
                                // from here, and it answers for itself.
                                onOpen()
                                return true
                            }
                            return onActivate(window)
                        },
                        onClose: source.window.map { window in { onClose(window) } },
                        onZoom: source.window.map { window in { onZoom(window) } },
                        onHover: { isInside in onHover(index, isInside) }
                    )
                }
            }
        }
        .padding(DockPreviewLayout.padding)
        .background { scrim }
        .environment(\.deckPalette, palette)
    }

    /// The whisper of scrim that keeps the header and captions readable.
    ///
    /// The deck window has had this since glass arrived and this panel never
    /// did, which is the one place Liquid Glass was genuinely half-applied here.
    /// Glass sits over whatever the user's desktop happens to be, and this panel
    /// opens against the bottom of the screen — over a wallpaper, someone else's
    /// document, a video — so 11pt secondary type on bare glass is legible over
    /// one backdrop and gone over the next. `DeckPalette.scrimStrength` already
    /// carries how much help each material needs, and clear glass needs
    /// considerably more than regular because it lets far more through.
    ///
    /// Nothing at all in solid mode, where the chosen ground already guarantees
    /// the contrast and darkening it would only muddy the colour.
    @ViewBuilder
    private var scrim: some View {
        let strength = palette.scrimStrength
        if strength > 0 {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.05 * strength),
                    Color.black.opacity(0.14 * strength),
                ],
                startPoint: .top, endPoint: .bottom
            )
            // Clipped to the panel's own shape, so it cannot paint square
            // shoulders into the corners the material has already rounded.
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DeckBackgroundView.cornerRadius, style: .continuous
                )
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: - Header

    /// Which app this is, and how much of it is being shown.
    ///
    /// The panel is drawn exactly where the Dock's own tooltip would have
    /// appeared and suppresses it, so without this the hover *removes* the one
    /// piece of information macOS was already giving. It matters most for a
    /// remembered still, where the picture is of a window that is gone and
    /// "Opens in a new window" is a promise about an app the panel never names.
    private var header: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
            }
            Text(target.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            if let summary = windowSummary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// The one thing about this row the row itself cannot tell you.
    ///
    /// Which is only ever that it is incomplete. A browser left open for a week
    /// owns thirty windows and the row is capped at six — presenting six as the
    /// whole answer would be saying something untrue about what is behind that
    /// icon — so that case, and the still's "nothing is open", are what this
    /// says.
    ///
    /// It deliberately says nothing else. It used to also count the windows and
    /// count the minimised ones among them, and both were already on screen: the
    /// thumbnails are countable by looking at them, and each minimised one now
    /// carries its own glyph in its caption, which says it per window rather
    /// than as a total. Restating them cost the header the width it needed for
    /// the parts that were not redundant — over a row of two narrow windows,
    /// "iPhone Mirroring · 2 windows · 2 minimised" truncated mid-word, so the
    /// panel was cut off saying twice what the pictures underneath said once.
    private var windowSummary: String? {
        if target.windows.isEmpty { return target.still != nil ? "no window open" : nil }

        let shown = target.windows.count
        let total = max(target.totalWindows, shown)
        return total > shown ? "\(shown) of \(total) windows" : nil
    }

    /// The owning app's icon: the header's, and the placeholder inside a
    /// thumbnail that has not received its first frame yet — a fraction of a
    /// second, but a visible one for a preview of six windows.
    ///
    /// Read once by the controller building the panel, alongside `sourceSizes`,
    /// rather than on every pass of this view's body. See the `icon` property.
    static func icon(for target: DockWindows.Target) -> NSImage? {
        guard let url = target.applicationURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - One thumbnail

private struct DockThumbnail: View {

    /// What this thumbnail is showing. The two cases differ in more than where
    /// the pixels come from: a live window can be closed and zoomed and its
    /// frame keeps arriving, while a remembered still is a photograph of
    /// something that is not there any more, and the most a click on it can do
    /// is reopen the document it was a picture of.
    enum Source {
        case window(WindowServerCapture.WindowRef)
        /// A still, and the document it is a picture of when that could be
        /// established — which is the only thing a click on it can promise.
        case remembered(AppWindowCapture.Capture, URL?)

        /// The window's own size, which is what its thumbnail's shape is
        /// derived from.
        var size: CGSize {
            switch self {
            case .window(let window): return window.bounds.size
            case .remembered(let capture, _): return capture.sourceSize
            }
        }

        var window: WindowServerCapture.WindowRef? {
            if case .window(let window) = self { return window }
            return nil
        }

        var windowID: CGWindowID? { window?.id }
    }

    let source: Source
    /// The live frame for this window, or nil for a still, which has none.
    let slot: LiveWindowPreview.Slot?
    /// Whether this is the thumbnail being acted on — the one under the pointer,
    /// or the one the arrow keys have stepped to.
    ///
    /// Passed down rather than kept here as hover state of its own. The keyboard
    /// can choose a thumbnail the pointer is nowhere near, and a thumbnail that
    /// decided its own highlight could not show that; worse, it would leave two
    /// thumbnails looking chosen at once.
    let isSelected: Bool
    /// Both measured by `DockPreviewLayout`: the height is shared by every
    /// thumbnail in the row, the width comes from this window's own shape.
    let width: CGFloat
    let height: CGFloat
    let icon: NSImage?
    let fallbackTitle: String
    /// Each returns whether the window was actually acted on. Close and zoom are
    /// nil for a remembered still, which has no window to act on.
    let onActivate: () -> Bool
    let onClose: (() -> Bool)?
    let onZoom: (() -> Bool)?
    let onHover: (Bool) -> Void

    @Environment(\.deckPalette) private var palette

    /// What was asked for and could not be done, or nil when nothing has failed.
    ///
    /// Some applications do not expose a minimized window through Accessibility
    /// at all — Notes, measured on macOS 26 — so there is no title-bar button
    /// anywhere to press and no window to raise. Saying so is the only honest
    /// thing left: a control that swallows the click and changes nothing reads
    /// as a broken app rather than as a window that cannot be reached.
    ///
    /// It carries the verb rather than being a plain flag, because all three
    /// actions fail this way and "Couldn't close" over a maximise that did
    /// nothing would be a worse answer than none.
    @State private var failure: String?

    /// Reading `slot.image` here is what subscribes this view to that one
    /// window, so a capture landing for a neighbouring thumbnail does not redraw
    /// this one.
    private var image: NSImage? {
        switch source {
        case .window: return slot?.image
        case .remembered(let capture, _): return capture.image
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                DeckSurfaceLayer(.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    placeholder
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : palette.cardBorder,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            // The only thing still drawn over the picture, and only ever
            // briefly: a click that was swallowed has to be answered where the
            // click happened.
            .overlay(alignment: .topLeading) { failureBadge }
            .overlay(alignment: .topTrailing) { controls }

            caption
                .frame(width: width)
        }
        .contentShape(Rectangle())
        .onHover { inside in onHover(inside) }
        .onTapGesture { attempt("reach it", onActivate) }
        .help(helpText)
        // The panel never takes key focus, so nothing here is reachable by tab —
        // but VoiceOver can still be pointed at it, and a thumbnail with no name
        // is announced as an unlabelled image. The help text is already the
        // sentence describing what a click does, so it is also the label.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(helpText)
        .accessibilityAddTraits(.isButton)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        // Clears the complaint again so the panel does not keep an old one on
        // screen. A task rather than a queued block, because SwiftUI cancels it
        // when this thumbnail goes — which, the panel being driven by the
        // pointer, is usually before the two and a half seconds are up.
        .task(id: failure) {
            guard failure != nil else { return }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation { failure = nil }
        }
    }

    /// Runs one of the three actions and says so on the thumbnail if it did not
    /// happen.
    private func attempt(_ verb: String, _ action: () -> Bool) {
        guard !action() else { return }
        withAnimation { failure = "Couldn’t \(verb)" }
    }

    // MARK: - Caption

    /// The window's title, the state it is in, and — for a still — what a click
    /// will do instead of returning to it.
    ///
    /// All of it below the picture rather than over it. The state used to be a
    /// pill in the thumbnail's top-left corner, which on a 132pt preview is
    /// nearly half its width and lands precisely on the title bar, toolbar or
    /// tab strip: the part of a screenshot that tells you which window this is,
    /// covered by a label telling you something you can also be told in the
    /// space underneath.
    private var caption: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                if let glyph = stateGlyph {
                    Image(systemName: glyph)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if case .remembered(_, let document) = source {
                // Quiet while the panel is only being looked at, and brought up
                // to the title's own weight under the pointer: this line is the
                // one thing telling the user that a click will *not* take them
                // back to the window in the picture, and the moment that matters
                // is the moment they are about to click it.
                Text(AppWindowCapture.openPromise(document: document))
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var title: String {
        switch source {
        case .window(let window):
            let title = window.title ?? ""
            return title.isEmpty ? fallbackTitle : title
        case .remembered(let capture, _):
            let title = capture.windowTitle ?? ""
            return title.isEmpty ? fallbackTitle : title
        }
    }

    /// Nothing for a window that is on screen right now, which needs no label:
    /// the user can see it, and a glyph beside every caption would say the
    /// ordinary case as loudly as the exceptional one.
    private var stateGlyph: String? {
        switch source {
        case .window(let window):
            return window.isOnScreen ? nil : "arrow.down.right.and.arrow.up.left"
        case .remembered:
            return "clock.arrow.circlepath"
        }
    }

    private var helpText: String {
        switch source {
        case .window(let window):
            return window.isOnScreen ? "Bring this window forward" : "Restore this window"
        case .remembered(_, let document):
            // Said in full here, and in short under the thumbnail. A still is a
            // photograph of a window that has been closed, so the one thing the
            // user cannot tell by looking is that clicking will not take them
            // back to it.
            return "No window of \(fallbackTitle) is open. "
                + "\(AppWindowCapture.openPromise(document: document))."
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: min(44, height * 0.34), height: min(44, height * 0.34))
                .opacity(0.55)
        }
    }

    @ViewBuilder
    private var failureBadge: some View {
        if let failure {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                Text(failure)
                    .font(.system(size: 9, weight: .medium))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .deckSurface(.chip, in: Capsule(), palette: palette)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
            .padding(6)
            .transition(.opacity)
        }
    }

    /// Close and maximise, revealed on the chosen thumbnail.
    ///
    /// Deliberately no minimise. A Dock preview is already the place minimised
    /// windows live, so a button that puts one *back* there is the one action
    /// the panel makes pointless — and the two that are worth having from here
    /// are the two the user would otherwise have to raise the window to reach.
    ///
    /// Only on the chosen one — under the pointer, or where the arrow keys have
    /// stepped to — because a preview is for looking at. Controls pinned
    /// permanently over every thumbnail would take space from the picture they
    /// sit on and turn a glance into a form.
    @ViewBuilder
    private var controls: some View {
        if isSelected, let onClose, let onZoom {
            HStack(spacing: DockPreviewLayout.controlSpacing) {
                control("xmark", help: "Close this window") {
                    attempt("close it", onClose)
                }
                control("arrow.up.left.and.arrow.down.right", help: "Maximise this window") {
                    attempt("maximise it", onZoom)
                }
            }
            // Two circles a few points apart are exactly the case grouping glass
            // is for: rendered in one pass they blend where they come close and
            // read as one cluster of controls, the way the system's own do,
            // instead of two separate pieces stuck on the picture. Safe here in a
            // way it is not around the row itself — there is no window image
            // inside this group to be composited under the material.
            .deckGlassGroup(spacing: 6, palette: palette)
            .padding(DockPreviewLayout.controlInset)
            .transition(.opacity)
        }
    }

    private func control(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: DockPreviewLayout.controlSize, height: DockPreviewLayout.controlSize)
                .deckSurface(.control, in: Circle(), palette: palette)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
        // A button whose whole label is an SF Symbol has no accessible name of
        // its own.
        .accessibilityLabel(help)
    }
}
