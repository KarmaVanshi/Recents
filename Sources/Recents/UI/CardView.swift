import AppKit
import SwiftUI

/// One card in the deck.
///
/// Geometry is driven entirely by `delta` — signed distance from the centre of
/// the rail in card units. Everything else (scale, tilt, dimming, depth) is a
/// function of it, which is what makes the rail read as a physical stack rather
/// than a list that happens to scroll sideways.
///
/// Two card shapes, per the design brief: documents keep the full portrait page
/// preview, while applications are landscape — their last window at roughly a
/// quarter of real window size.
struct CardView: View {

    let item: RecentItem
    let delta: CGFloat
    let isSelected: Bool
    /// Card sizes for the window as it currently stands — see `DeckMetrics`.
    let metrics: DeckMetrics
    /// Changes whenever a new window screenshot lands, so app cards refresh.
    let captureGeneration: Int

    let onOpen: () -> Void
    let onFlick: () -> Void
    /// Set only on application cards that actually have recents of their own.
    /// Nil means the swipe-down gesture is not offered at all, which is what
    /// keeps it from being a gesture that silently does nothing.
    var onDrillDown: (() -> Void)?
    let onTogglePin: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onSelect: () -> Void

    @Environment(\.deckPalette) private var palette
    /// Whether this card's window is the front one — see `showsQuickActions`.
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var dragOffset: CGSize = .zero
    @State private var isFlickingAway = false
    @State private var isHovering = false

    private var isApplication: Bool { item.kind == .application }

    private var cardSize: CGSize {
        isApplication ? metrics.applicationSize : metrics.documentSize
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
    }

    /// The strip above the card that the quick actions live in.
    ///
    /// The bar used to be pinned inside the card's top-right corner, where it
    /// covered the one part of the preview a user is most likely to be reading —
    /// a document's heading, an app window's toolbar. It is the *selected*
    /// card's bar, and the selected card is the one whose picture matters most,
    /// so the bar had been placed to obscure exactly the thing it was decorating.
    /// The rail already leaves this strip empty above every card.
    ///
    /// Unscaled, like the bar itself: these are controls at pointer size, not
    /// part of the card's artwork, so they stay the size a control should be
    /// however large the window is dragged.
    private static let actionBarBand: CGFloat = 44

    /// How far the card's own top edge sits below the top of the band the rail
    /// gives it. Zero for documents, which fill the band; half the difference
    /// for landscape application cards, which are centred in it.
    private var cardTopInset: CGFloat {
        (metrics.documentSize.height - cardSize.height) / 2
    }

    private var absDelta: CGFloat { abs(delta) }

    /// Cards shrink as they recede, but the falloff is clamped so the far ends
    /// of a long deck stay legible instead of collapsing to slivers.
    private var scale: CGFloat {
        max(0.62, 1 - min(absDelta, 4) * 0.11)
    }

    /// Cards angle away from the centre like pages in a fanned stack.
    private var tilt: Double {
        let clamped = max(-1, min(1, delta))
        return Double(clamped) * -20 - Double(delta - clamped) * 2
    }

    private var dim: Double {
        isSelected ? 0 : min(0.32, Double(absDelta) * 0.11)
    }

    /// Captions are full card width, so on an overlapping rail every neighbour's
    /// label lands on top of the next. Only the centred card is titled; the rest
    /// fade out fast enough that two are never legible at once.
    private var captionOpacity: Double {
        max(0, 1 - Double(absDelta) * 2.2)
    }

    var body: some View {
        // The quick actions are a *sibling* of the gesture-carrying stack, not a
        // child of it. A `TapGesture` on an ancestor takes precedence over a
        // `Button` underneath it — the opposite of the usual "innermost gesture
        // wins" rule — so while the bar lived inside the card every one of its
        // buttons was dead: the click was swallowed by the card's own tap, which
        // selected or opened the item instead. As a sibling drawn above the card
        // it wins the hit test on its own, and the card still owns every click
        // that lands anywhere else. (The flick gesture is not the problem:
        // `minimumDistance` makes a drag yield to a button correctly.)
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Empty whether or not the bar is up, so raising it moves
                // nothing: a toolbar that pushed the card down as it appeared
                // would make the rail jump every time the selection changed.
                Color.clear.frame(height: Self.actionBarBand)

                VStack(spacing: metrics.captionGap) {
                    // Both shapes occupy the same vertical band so a mixed rail of
                    // apps and documents keeps one consistent centre line.
                    ZStack { card }
                        .frame(width: metrics.documentSize.width, height: metrics.documentSize.height)

                    caption
                }
                .gesture(flickGesture)
                .gesture(tapGesture)
            }

            if showsQuickActions {
                quickActions
                    .frame(height: Self.actionBarBand)
                    // Down to meet the card's own top edge. Application cards are
                    // landscape and sit centred in the taller band the rail gives
                    // every card, so a bar pinned to the band would float further
                    // and further above the picture it belongs to as the window
                    // grew — by a full 144pt at the largest size.
                    .offset(y: cardTopInset)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsQuickActions)
        .scaleEffect(scale)
        // `cacheDisplay` (used by --render) cannot composite 3D transforms and
        // draws such layers at their untransformed origin, which makes snapshots
        // look broken even when the live layout is correct. --flat skips the
        // rotation so a snapshot reflects real positions.
        .rotation3DEffect(
            .degrees(RenderOptions.flattenTransforms ? 0 : tilt),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.55
        )
        .offset(dragOffset)
        .opacity(isFlickingAway ? 0 : 1)
        .zIndex(-Double(absDelta))
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: delta)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragOffset)
        .onHover { isHovering = $0 }
    }

    /// The bar belongs to the card at the front of the rail, and to no other.
    ///
    /// Hover used to raise it on any card under the pointer, which put working
    /// controls on receding, tilted neighbours — cards the rest of the deck does
    /// not consider current. Every other action in here already means "the
    /// centred item": ⌘P pins it, Space peeks it, ↩ opens it. A bar that could
    /// act on a different card than the keyboard does is a second, competing
    /// idea of which item you are addressing, so it now follows the same one.
    ///
    /// Bring a neighbour forward — scroll, arrow, or click it — and the bar comes
    /// with it.
    ///
    /// The window test is separate: the deck is an ordinary window that can be
    /// left open behind other apps, and a background window's first click is
    /// spent activating it rather than pressing what is under the pointer, so a
    /// bar shown on a buried deck would be one whose buttons genuinely do nothing
    /// until the second click. `.key` means this window is the key window *of the
    /// active application*, which is exactly the condition worth waiting for.
    private var showsQuickActions: Bool {
        isDeckFrontmost && isSelected
    }

    /// `--render` draws into an offscreen window that is never key, so without
    /// this the snapshot would show a deck missing chrome that ships.
    private var isDeckFrontmost: Bool {
        RenderOptions.assumesFrontmost || controlActiveState == .key
    }

    /// One gesture rather than two stacked `onTapGesture` modifiers.
    ///
    /// Stacked, both handlers ran: the single-tap one fires on the way to a
    /// double tap, and for a selected card both of them called `onOpen()`. It
    /// never showed up as a double launch only because the first `open()` hides
    /// the deck before the second lands — which is luck, not design.
    /// `exclusively(before:)` states the intent instead: the double tap gets
    /// first refusal, and the single tap runs only once the double has failed.
    private var tapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded { onOpen() }
            .exclusively(
                before: TapGesture(count: 1)
                    .onEnded { isSelected ? onOpen() : onSelect() }
            )
    }

    // MARK: - Card face

    private var card: some View {
        ZStack(alignment: .bottomLeading) {
            // Only visible where the preview does not reach — a card whose
            // thumbnail is still loading, or an app with no capture. Over a glass
            // window an opaque fill reads as a paper slab stuck to the pane, so
            // the ground is the same material as the window itself.
            DeckSurfaceLayer(.card, in: cardShape)

            preview
                .frame(width: cardSize.width, height: cardSize.height)
                .clipShape(cardShape)

            // Keeps the app badge readable over light previews.
            LinearGradient(
                colors: [.black.opacity(0.5), .clear],
                startPoint: .bottom, endPoint: .center
            )
            .clipShape(cardShape)
            .allowsHitTesting(false)

            HStack(spacing: 8) {
                appIcon
                originBadge
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(.orange))
                }
                Spacer()
            }
            .padding(11)

            // Says the card has more inside it. Without this the swipe is
            // invisible, and it would do nothing on four cards out of five —
            // most apps register no recent documents at all.
            if onDrillDown != nil {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white.opacity(isSelected || isHovering ? 0.95 : 0.55))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 9)
                    .background(Capsule().fill(.black.opacity(0.35)))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 7)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .overlay(
            cardShape.strokeBorder(
                isSelected ? Color.accentColor : palette.cardBorder,
                lineWidth: isSelected ? 2 : 1
            )
        )
        .overlay(
            cardShape
                .fill(.black.opacity(dim))
                .allowsHitTesting(false)
        )
        // Two shadows on the centred card: the ordinary one that lifts it off
        // the rail, and an accent-tinted glow underneath it. Selection used to
        // be carried by a 3pt ring alone, which is a lot of saturated colour to
        // draw around a photograph — thinning the ring and letting the card sit
        // in its own light says the same thing without competing with the
        // picture for attention.
        .shadow(color: isSelected ? Color.accentColor.opacity(0.22) : .clear, radius: 20)
        .shadow(color: .black.opacity(isSelected ? 0.4 : 0.22),
                radius: isSelected ? 26 : 14, y: isSelected ? 12 : 7)
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .application:
            AppWindowImage(
                item: item, size: cardSize, generation: captureGeneration,
                isHovered: isHovering,
                // The centred card already carries its recency in the caption
                // underneath it, so the badge there says only what the caption
                // cannot: that the picture is a still rather than the live
                // window. Neighbours have no legible caption, so theirs keeps
                // the age.
                showsAge: !isSelected,
                // Attention drives the live-preview refresh rate: the card being
                // looked at animates, its neighbours tick over, the rest are not
                // captured at all.
                attention: isSelected || isHovering ? .focused
                    : (absDelta < 3 ? .visible : nil)
            )
        case .document:
            ThumbnailImage(url: item.url, size: cardSize)
        case .server:
            ServerImage(item: item, size: cardSize)
        }
    }

    private var appIcon: some View {
        Group {
            if let app = item.owningApp {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: metrics.badgeSize, height: metrics.badgeSize)
            }
        }
    }

    /// Marks the cards that macOS's own Recent Items menu does not contain.
    ///
    /// Spotlight supplies most of the deck's breadth — the Apple menu holds about
    /// ten documents and Spotlight sees hundreds — but "the Apple menu would show
    /// this" and "we found this ourselves" are different claims, and a deck that
    /// blurs them cannot honestly say it mirrors the Apple menu. Small, quiet, and
    /// explained on hover: it is a provenance note, not a warning.
    @ViewBuilder
    private var originBadge: some View {
        if item.origin == .spotlight {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(4)
                .background(Circle().fill(.black.opacity(0.35)))
                .help("Found by Spotlight — not in the Apple menu's Recent Items list")
        }
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        HStack(spacing: 6) {
            actionButton("pin.fill", "Pin", active: item.isPinned, action: onTogglePin)
            actionButton("folder", isApplication ? "Show in Finder" : "Reveal in Finder", action: onReveal)
            actionButton("doc.on.clipboard", "Copy path", action: onCopyPath)
            actionButton("xmark", "Forget", action: onFlick)
        }
        .padding(6)
        .deckSurface(.control, in: Capsule(), palette: palette)
    }

    private func actionButton(
        _ symbol: String, _ help: String,
        active: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(active ? Color.orange : Color.primary)
                // Without this the target is the glyph, not the frame: a plain
                // button hit-tests what its label draws, and an 11pt symbol drew
                // about 8×12pt of it. Inside the label, so the whole 22×22 counts
                // — on the button itself it would have no effect at all.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Caption

    private var caption: some View {
        VStack(spacing: 3) {
            Text(item.displayName)
                .font(.system(size: metrics.titleFontSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.subtitle)
                .font(.system(size: metrics.subtitleFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: metrics.documentSize.width)
        .opacity(captionOpacity)
        // Removed from the hit-test as well as hidden, so a faded caption cannot
        // intercept clicks meant for the card behind it.
        .allowsHitTesting(captionOpacity > 0.5)
    }

    // MARK: - Flick to forget

    private var flickGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // Upward drags travel freely. Downward ones do too, but only on
                // a card that can expand — on every other card the old damping
                // stands, so the gesture still reads as one-directional there.
                let dy = value.translation.height
                let downwardTravel = onDrillDown != nil ? dy * 0.55 : dy * 0.15
                dragOffset = CGSize(
                    width: value.translation.width * 0.18,
                    height: dy < 0 ? dy : downwardTravel
                )
            }
            .onEnded { value in
                let travel = value.translation.height
                let projected = value.predictedEndTranslation.height

                // Down expands the card into that app's own recents. Checked
                // before the flick so the two can share one drag gesture, and
                // only offered when there is something to expand into.
                if let onDrillDown, travel > 90 || projected > 220 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragOffset = .zero
                    }
                    onDrillDown()
                    return
                }

                // Either a decisive drag or a quick flick counts — matching the
                // iPhone app switcher, where a short fast flick is enough.
                if travel < -90 || projected < -220 {
                    isFlickingAway = true
                    withAnimation(.easeIn(duration: 0.2)) {
                        dragOffset = CGSize(width: dragOffset.width, height: -700)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        onFlick()
                    }
                } else {
                    dragOffset = .zero
                }
            }
    }
}

/// A network volume's face. There is nothing to preview — an unmounted share has
/// no contents to render and reaching for them would mean a blocking network
/// round trip — so this states what it is and leaves it at that.
private struct ServerImage: View {

    let item: RecentItem
    let size: CGSize

    @Environment(\.deckPalette) private var palette

    var body: some View {
        ZStack {
            DeckSurfaceLayer(.card, in: Rectangle())
            LinearGradient(
                colors: [Color.primary.opacity(0.04), Color.primary.opacity(0.10)],
                startPoint: .top, endPoint: .bottom
            )
            VStack(spacing: 12) {
                Image(nsImage: NSImage(named: NSImage.networkName) ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width * 0.34, height: size.width * 0.34)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                if let host = item.url.host {
                    Text(host)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// An application card's face.
///
/// Three sources, in descending order of truth:
///
///   1. A **live frame** from `LiveWindowPreview` — the window as it is right
///      now, updating many times a second. This works even when the window is
///      minimized, which is the whole point: a video playing in a minimized
///      window plays here too, the way a Windows taskbar thumbnail does.
///   2. The **last captured still**, from `AppWindowCapture`. This is what a
///      quit application falls back to, and it survives relaunches.
///   3. The app's **icon**, when we have genuinely never seen a window from it.
///
/// Whichever it is, the card says so. A still presented as live when the app has
/// been closed for a day is a lie the user cannot detect from the image alone —
/// and equally, a live frame from a minimized window is worth labelling, because
/// the user is being shown something they cannot see anywhere else on screen.
private struct AppWindowImage: View {

    let item: RecentItem
    let size: CGSize
    let generation: Int
    /// Whether the pointer is on this card, which is when its badge stops
    /// reporting how old the still is and starts saying what clicking will do.
    let isHovered: Bool
    /// Whether the badge should date the still. False on the centred card,
    /// whose caption is legible and already says when the app was last used —
    /// two ages on one card is noise, and the badge sits over the picture.
    let showsAge: Bool
    /// How much refresh this card should be getting, or nil for none.
    let attention: LiveWindowPreview.Demand?

    @Environment(\.deckPalette) private var palette

    /// The engine's slot for this app. Held rather than looked up in `body`,
    /// because vending a slot inserts it into the engine's table and mutating
    /// shared state during a view update is exactly the sort of thing SwiftUI is
    /// entitled to complain about.
    @State private var slot: LiveWindowPreview.Slot?
    /// Which app the held slot belongs to.
    ///
    /// Recorded because "have we got a slot" and "have we got *this app's* slot"
    /// are different questions, and only the second one is worth asking. The
    /// rebind below used to ask the first: it dropped the old app's demand and
    /// then kept the old app's slot, so a card handed a new item went on drawing
    /// live frames of the app it used to be.
    @State private var slotBundleID: String?

    private var capture: AppWindowCapture.Capture? {
        guard let bundleID = item.bundleID else { return nil }
        return AppWindowCapture.shared.capture(forBundleID: bundleID)
    }

    private var presence: AppWindowCapture.Presence {
        guard let bundleID = item.bundleID else { return .notRunning }
        return AppWindowCapture.shared.presence(forBundleID: bundleID)
    }

    /// Reading `slot.image` here is what registers this view as an observer of
    /// that one slot, so a frame landing for another app does not redraw us.
    private var liveImage: NSImage? {
        guard let slot, slot.isLive else { return nil }
        return slot.image
    }

    var body: some View {
        ZStack {
            if let image = liveImage ?? capture?.image {
                DeckSurfaceLayer(.card, in: Rectangle())
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: displaySize(for: image).width,
                        height: displaySize(for: image).height
                    )
            } else {
                iconFallback
            }
        }
        // An overlay rather than another stack child, so pinning the badge to a
        // corner does not drag the centred preview into it too.
        .overlay(alignment: .bottomTrailing) { badge }
        .onAppear { subscribe() }
        .onDisappear { unsubscribe() }
        .onChange(of: attention) { _, _ in subscribe() }
        .onChange(of: item.bundleID) { old, _ in
            if let old { LiveWindowPreview.shared.setDemand(nil, for: old) }
            subscribe()
        }
    }

    // MARK: - Live subscription

    private func subscribe() {
        guard let bundleID = item.bundleID else { return }
        // Only when it is actually a different app: assigning the same slot again
        // would invalidate this view on every change of attention, which is every
        // card the rail passes under the pointer.
        if slotBundleID != bundleID {
            slot = LiveWindowPreview.shared.slot(for: bundleID)
            slotBundleID = bundleID
        }
        LiveWindowPreview.shared.setDemand(attention, for: bundleID)
    }

    private func unsubscribe() {
        guard let bundleID = item.bundleID else { return }
        LiveWindowPreview.shared.setDemand(nil, for: bundleID)
    }

    // MARK: - Presentation

    /// Same rule as document thumbnails: fit, and never enlarge past what was
    /// actually captured. A window frame is normally far larger than the card, so
    /// this only bites on genuinely small windows.
    private func displaySize(for image: NSImage) -> CGSize {
        let native = image.size
        guard native.width > 0, native.height > 0 else { return size }
        let factor = min(min(size.width / native.width, size.height / native.height), 1)
        return CGSize(width: native.width * factor, height: native.height * factor)
    }

    @ViewBuilder
    private var badge: some View {
        if let slot, slot.isLive {
            // Only worth saying when the window is somewhere the user cannot see
            // it. A live preview of a window that is right there on screen needs
            // no label.
            if slot.isOffScreen {
                pill(
                    icon: "dot.radiowaves.left.and.right",
                    text: "Live",
                    tint: .green,
                    help: "This window is minimised or hidden. You are seeing it live."
                )
            }
        } else if let capture, presence != .live {
            // Hovering swaps the age for the promise. What the user wants to
            // know while merely looking at a card is how old the picture is;
            // what they want to know with the pointer on it is where a click
            // lands — and a still cannot lead back to the window it shows.
            //
            // `document: nil` is not a gap. A deck card stands for an
            // application and opening one opens the app, never a particular
            // file, so a new empty window is exactly what this click does. The
            // Dock's panel is where a still stands for one document and can
            // promise to reopen it.
            pill(
                icon: isHovered
                    ? "arrow.up.forward.app"
                    : (presence == .notRunning ? "moon.zzz.fill" : "rectangle.on.rectangle"),
                text: isHovered
                    ? AppWindowCapture.openPromise(document: nil)
                    : (showsAge ? age(capture.capturedAt) : ""),
                tint: .white.opacity(0.9),
                help: (presence == .notRunning
                    ? "This app is not running. Showing the last window Recents saw."
                    : "No window on screen. Showing the last window Recents saw.")
                    + " \(AppWindowCapture.openPromise(document: nil))."
            )
        }
    }

    private func pill(icon: String, text: String, tint: Color, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            // An empty label collapses the pill to its glyph rather than
            // leaving a capsule with a gap in it where words used to be.
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.45)))
        .padding(9)
        .help(help)
    }

    private func age(_ date: Date) -> String {
        guard date > .distantPast else { return "last seen" }
        return RelativeDateTimeFormatter.shared.localizedString(for: date, relativeTo: Date())
    }

    private var iconFallback: some View {
        ZStack {
            DeckSurfaceLayer(.card, in: Rectangle())
            LinearGradient(
                colors: [Color.primary.opacity(0.04), Color.primary.opacity(0.10)],
                startPoint: .top, endPoint: .bottom
            )
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size.height * 0.44, height: size.height * 0.44)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
    }
}
