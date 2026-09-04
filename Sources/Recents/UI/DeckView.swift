import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The window's root view: a horizontal fan of recent applications and documents.
///
/// Card positions are driven by `scrollPosition`, a fractional index into the
/// filtered list. Keeping position as one continuous number (rather than using a
/// `ScrollView`) is what lets tilt, depth and parallax stay exactly in sync while
/// scrubbing, and makes keyboard and trackpad navigation share one code path.
///
/// When circular mode is on, that index wraps: each card's distance from centre
/// is measured the short way around the ring, so the deck has no ends.
struct DeckView: View {

    let store: RecentsStore
    let controller: DeckWindowController

    @State private var scrollPosition: CGFloat = 0
    @State private var selectedIndex: Int = 0
    @State private var filterText: String = ""
    @State private var isPeeking = false
    @State private var notice: DeckNotice?
    @State private var isConfirmingClear = false
    @State private var monitors: [Any] = []
    @State private var captureGeneration = 0
    @State private var filterCache = FilterCache()
    @State private var drillDown: DrillDown?
    /// Accumulated travel of the current two-finger vertical swipe, and whether
    /// it has already been acted on — one drill-in per gesture, not per event.
    @State private var verticalSwipeTravel: CGFloat = 0
    @State private var verticalSwipeHandled = false
    /// Which way the next deck transition should travel. Set on the way in and
    /// on the way out so the rail moves with the gesture rather than against it.
    @State private var isDrillingIn = true

    /// One application card, expanded into its own recents.
    ///
    /// The documents are snapshotted on entry rather than recomputed: the rail
    /// must not reshuffle underneath the user because a background refresh
    /// landed while they were looking at it. The saved position is what the main
    /// deck is restored to on the way back out.
    private struct DrillDown {
        let app: RecentItem
        let documents: [RecentItem]
        let savedIndex: Int
        let savedScroll: CGFloat
        let savedFilter: String
    }

    private let prefs = Preferences.shared

    /// Rebuilt on every redraw from the appearance preference, and pushed into
    /// the environment so cards, captions and the peek all paint from one source.
    private var palette: DeckPalette {
        DeckPalette(
            appearance: RenderOptions.appearance,
            ground: prefs.resolvedSolidBackground,
            style: prefs.glassStyle,
            tint: prefs.glassTint
        )
    }

    /// The deck as filtered, computed once per change rather than once per read.
    ///
    /// `body` reads this many times in a single pass — for `isEmpty`, for the
    /// header count, for the `ForEach`, for every `isCircular` check, and twice
    /// more inside `delta(for:)` for each rendered card — which came to roughly
    /// twenty-five full fuzzy passes per frame. At forty items that is about
    /// half the 16.7 ms frame budget spent re-deriving a list that has not
    /// changed, and it scales with the deck. Memoising on the two inputs keeps
    /// every call site as it was while collapsing that to one pass.
    ///
    /// Reading `store.items` on every call is deliberate: that is what registers
    /// the `@Observable` dependency, so a refresh still invalidates the view.
    private var items: [RecentItem] {
        filterCache.items(matching: filterText, in: drillDown?.documents ?? store.items)
    }

    /// Wrapping only makes sense once there are enough cards to form a ring;
    /// below that it just makes two cards jitter back and forth — `DeckRail`
    /// applies that floor itself.
    private var rail: DeckRail {
        DeckRail(count: items.count, isCircular: prefs.isCircular)
    }

    private var isCircular: Bool { rail.isCircular }

    var body: some View {
        ZStack {
            // The window itself supplies the ground — glass or solid, under this
            // hierarchy. All that is left to do here is *not* paint over it —
            // plus a whisper of scrim, so captions and key hints keep their
            // contrast when the glass happens to be sitting over a bright
            // desktop. Anything heavier and it stops reading as glass. A solid
            // ground already guarantees that contrast, so it gets no scrim at all
            // and the chosen colour comes through exactly as chosen.
            LinearGradient(
                colors: [
                    Color.black.opacity(0.03 * palette.scrimStrength),
                    Color.black.opacity(0.11 * palette.scrimStrength),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                header

                Group {
                    if items.isEmpty {
                        emptyState
                    } else {
                        deck
                    }
                }
                // Identity, so entering or leaving a sub-deck is a replacement
                // the transition can animate rather than the same rail quietly
                // changing its contents underneath the user.
                .id(drillDown?.app.url.path ?? "")
                .transition(deckTransition)

                footer
            }
            .padding(.top, 18)
            .padding(.bottom, 14)

            if isPeeking, let item = currentItem {
                PeekView(item: item) { isPeeking = false }
                    .transition(.opacity)
                    .zIndex(1000)
            }
        }
        .environment(\.deckPalette, palette)
        .animation(.easeOut(duration: 0.18), value: isPeeking)
        .onAppear {
            installMonitors()
            AppWindowCapture.shared.onUpdate = { captureGeneration &+= 1 }
        }
        .onDisappear {
            removeMonitors()
            // Otherwise every window capture keeps pushing state into a view that
            // is no longer on screen, and the closure keeps this deck's state
            // alive for the life of the process.
            AppWindowCapture.shared.onUpdate = nil
        }
        // A dismissed deck should come back the way it opens, not the way it was
        // left. `onDisappear` cannot do this — the window is ordered out, not
        // torn down — so the controller says so explicitly.
        .onReceive(NotificationCenter.default.publisher(for: .recentsDeckDidHide)) { _ in
            isPeeking = false
            isConfirmingClear = false
            notice = nil
        }
        .onChange(of: filterText) { _, _ in
            // Any change to the result set invalidates the current position.
            selectedIndex = 0
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                scrollPosition = 0
            }
        }
    }

    private var currentItem: RecentItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let drillDown {
                    // Says where you are and how to get back, since a sub-deck
                    // of documents is otherwise indistinguishable from the deck.
                    Image(nsImage: NSWorkspace.shared.icon(forFile: drillDown.app.url.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(drillDown.app.displayName)
                        .font(.system(size: 16, weight: .semibold))
                    Text("· Recents")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Recent Items")
                        .font(.system(size: 16, weight: .semibold))
                }
                Text("· \(items.count)")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                if isCircular {
                    Image(systemName: "repeat")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help("Circular browsing is on")
                }
            }

            if !filterText.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(filterText)
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .deckSurface(.chip, in: Capsule(), palette: palette)
                .transition(.opacity)
            }

            if store.needsFullDiskAccess {
                banner(
                    icon: "lock.fill",
                    text: "Can't read macOS's Recent Items — grant Full Disk Access for exact Apple-menu order",
                    tint: .orange
                ) {
                    openSettingsPane("Privacy_AllFiles")
                }
            }

            if !AppWindowCapture.shared.hasPermission && prefs.showApplications {
                banner(
                    icon: "camera.viewfinder",
                    text: "Allow Screen Recording to show each app's last window instead of its icon",
                    tint: .blue
                ) {
                    AppWindowCapture.shared.requestPermission()
                    openSettingsPane("Privacy_ScreenCapture")
                }
            }
        }
        .padding(.bottom, 10)
    }

    private func banner(
        icon: String, text: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(text)
                Image(systemName: "arrow.right.circle.fill")
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func openSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private var footer: some View {
        ZStack {
            if let notice {
                HStack(spacing: 10) {
                    Text(notice.text).font(.system(size: 12))
                    // Only a flick can be taken back. Clearing the Apple menu
                    // cannot, so offering the button there would be a lie.
                    if notice.isUndoable {
                        Button("Undo") { performUndo() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("⌘Z").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 9)
                .deckSurface(.chip, in: Capsule(), palette: palette)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                KeyHintBar(
                    isDrilledIn: drillDown != nil,
                    canDrillDown: currentItem.map(canDrillInto) ?? false
                )
            }
        }
        .frame(height: 34)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: notice)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filterText.isEmpty ? "clock" : "magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(filterText.isEmpty ? "No recent items yet" : "Nothing matches “\(filterText)”")
                .font(.system(size: 15, weight: .medium))
            if !filterText.isEmpty {
                Text("Press ⎋ to clear the filter")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The rail

    private var deck: some View {
        GeometryReader { geo in
            // Explicit `.position` rather than `.offset` inside a centred stack:
            // offset is relative to wherever layout happened to put the view,
            // which with 3D-rotated, differently-scaled children is not reliably
            // the centre. Positioning against the geometry makes each card's
            // placement a pure function of its delta.
            let centerX = geo.size.width / 2
            let centerY = geo.size.height / 2
            // Cards, captions and rail spacing are all sized from the room the
            // rail has, so a bigger window means a bigger deck rather than the
            // same deck with more empty ground around it.
            let metrics = DeckMetrics(available: geo.size)

            ZStack(alignment: .topLeading) {
                Color.clear

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let delta = self.delta(for: index)

                    // Cards far outside the viewport are never built — with a
                    // hundred recents, rendering them all would make the window
                    // visibly stutter on open.
                    if abs(delta) < 5 {
                        CardView(
                            item: item,
                            delta: delta,
                            isSelected: index == selectedIndex,
                            metrics: metrics,
                            captureGeneration: captureGeneration,
                            onOpen: { open(item) },
                            // Inside a sub-deck an upward flick leaves it rather
                            // than forgetting the document. Flicking away a card
                            // you reached by drilling in would suppress it from
                            // the *main* deck too, which is not what the gesture
                            // looks like it is doing from in here.
                            onFlick: { drillDown == nil ? flick(item) : popDrillDown() },
                            onDrillDown: canDrillInto(item) ? { drillInto(item) } : nil,
                            onTogglePin: { store.togglePin(item) },
                            onReveal: { controller.hide(); store.revealInFinder(item) },
                            onCopyPath: { store.copyPath(item) },
                            onSelect: { select(index) }
                        )
                        .position(
                            x: centerX + xOffset(for: delta, spacing: metrics.spacing),
                            y: centerY
                        )
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .mask(railEdgeFade(across: geo.size.width))
        }
        .frame(maxHeight: .infinity)
    }

    /// Dissolves the rail at the window's left and right edges.
    ///
    /// A rail wider than its window has to end somewhere, and a hard edge ends
    /// it with a vertical cut straight through a card — which reads as a
    /// rendering fault rather than as a deck that carries on past the frame.
    /// The fade is narrow, and the outermost card's centre stays well inside
    /// it, so a card can still be clicked to bring it forward.
    private func railEdgeFade(across width: CGFloat) -> some View {
        // A zero-width rail has nothing to fade and would divide by zero
        // working out where to put the stops.
        let fade = width > 1 ? min(56, width * 0.08) / width : 0
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: fade),
                .init(color: .black, location: 1 - fade),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// Signed distance from the centre of the rail, in card units. See
    /// `DeckRail`, which owns this and the rest of the rail's arithmetic.
    private func delta(for index: Int) -> CGFloat {
        rail.delta(for: index, scrollPosition: scrollPosition)
    }

    private func xOffset(for delta: CGFloat, spacing: CGFloat) -> CGFloat {
        rail.xOffset(for: delta, spacing: spacing)
    }

    // MARK: - Navigation

    private func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        selectedIndex = index
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            scrollPosition = railPosition(for: index)
        }
    }

    /// The rail position that centres `index` — see `DeckRail.railPosition`.
    private func railPosition(for index: Int) -> CGFloat {
        rail.railPosition(for: index, scrollPosition: scrollPosition)
    }

    private func move(by step: Int) {
        let rail = self.rail
        guard !rail.isEmpty else { return }

        let next = rail.index(after: selectedIndex, step: step)
        selectedIndex = next
        let target = rail.scrollTarget(from: scrollPosition, movingBy: step, to: next)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            scrollPosition = target
        }
    }

    private func flick(_ item: RecentItem) {
        let name = item.displayName
        store.suppress(item)
        show(DeckNotice(text: "Removed “\(name)” from Recents", isUndoable: true))

        // Keep the selection somewhere sensible now that the list is shorter.
        selectedIndex = min(selectedIndex, max(items.count - 1, 0))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            scrollPosition = railPosition(for: selectedIndex)
        }
    }

    /// The single way out of the deck and into an item, from any of the three
    /// gestures that mean "open this": Return, a click on the centred card, and a
    /// double-click while peeking.
    ///
    /// Closing the peek first is not cosmetic. The window is ordered out rather
    /// than torn down, so this view — and every `@State` on it — survives being
    /// dismissed. A peek left standing here is still standing the next time the
    /// hotkey is pressed, and the deck reopens on top of a preview of whatever
    /// the user opened last time.
    private func open(_ item: RecentItem) {
        isPeeking = false
        // Inside an app's sub-deck everything belongs to that app, including how
        // it opens. Sending VS Code's `Recent` folder to `NSWorkspace.open`
        // would hand it to Finder, which is not what drilling in from the VS
        // Code card means.
        if let drillDown, item.kind != .application {
            controller.open(item, using: drillDown.app.url)
        } else {
            controller.open(item)
        }
    }

    // MARK: - Drilling into an application

    /// The sub-deck arrives from the direction the gesture pushed it: drilling
    /// in lifts the new rail up from below while the old one leaves upward, and
    /// backing out runs the same motion in reverse.
    private var deckTransition: AnyTransition {
        let travel: CGFloat = isDrillingIn ? 34 : -34
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.95))
                .combined(with: .offset(y: travel)),
            removal: .opacity
                .combined(with: .scale(scale: 0.95))
                .combined(with: .offset(y: -travel))
        )
    }

    /// Only application cards, only in the main deck, and only when the app has
    /// recents of its own — no sub-decks inside sub-decks.
    private func canDrillInto(_ item: RecentItem) -> Bool {
        drillDown == nil && item.kind == .application && store.hasRecentDocuments(item)
    }

    /// Expands an application card into that app's own recent documents.
    private func drillInto(_ item: RecentItem) {
        guard drillDown == nil, item.kind == .application else { return }
        let documents = store.recentDocuments(forApp: item)
        guard !documents.isEmpty else { return }

        isPeeking = false
        isDrillingIn = true
        let entering = DrillDown(
            app: item, documents: documents,
            savedIndex: selectedIndex, savedScroll: scrollPosition,
            savedFilter: filterText
        )
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            drillDown = entering
            filterText = ""
            selectedIndex = 0
            scrollPosition = 0
        }
    }

    /// Returns to the main deck, exactly where it was left.
    private func popDrillDown() {
        guard let drillDown else { return }
        isPeeking = false
        isDrillingIn = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            self.drillDown = nil
            filterText = drillDown.savedFilter
            selectedIndex = drillDown.savedIndex
            scrollPosition = drillDown.savedScroll
        }
    }

    /// Rebuilds the deck from its sources now, rather than waiting for a file
    /// watcher to notice.
    ///
    /// The sources are watched and the deck normally keeps itself current, but
    /// "normally" is doing work there: Spotlight's gather is asynchronous, an
    /// app's own list is rewritten whenever it feels like it, and a user who
    /// has just saved a file and does not see it has no way to ask again short
    /// of quitting. The notice is the point as much as the refresh — without
    /// it, a shortcut that finds nothing new is indistinguishable from one that
    /// is not bound at all.
    private func reload() {
        store.refresh()
        let count = store.items.count
        show(DeckNotice(
            text: count == 1 ? "Refreshed — 1 item" : "Refreshed — \(count) items",
            isUndoable: false
        ))
    }

    private func performUndo() {
        if let restored = store.undoSuppress(),
           let index = items.firstIndex(where: { $0.url == restored }) {
            select(index)
        }
        withAnimation { notice = nil }
    }

    /// Puts a line in the footer and takes it away again a few seconds later,
    /// unless something else has replaced it in the meantime.
    private func show(_ next: DeckNotice) {
        withAnimation { notice = next }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if notice == next { withAnimation { notice = nil } }
        }
    }

    // MARK: - Clear Menu

    /// ⇧⌘⌫ is the Apple menu's "Recent Items ▸ Clear Menu", performed for real.
    ///
    /// The question and the clearing both live in `ClearMenuPrompt`, which the
    /// menu bar shares — see there for why the copy is not written twice.
    private func confirmClearMenu() {
        // The sheet takes key status, so the deck's monitor stops seeing keys
        // while it is up — but the sheet is presented asynchronously, and two
        // fast presses in that gap would stack two alerts on one window.
        guard !isConfirmingClear else { return }
        isConfirmingClear = true

        ClearMenuPrompt.run(attachedTo: NSApp.keyWindow as? DeckWindow) { outcome in
            isConfirmingClear = false
            guard let outcome else { return }
            store.refresh()
            // Not undoable, and offering the button would be a lie: the menu
            // item this mirrors has no undo either.
            show(DeckNotice(text: outcome, isUndoable: false))
        }
    }

    // MARK: - Input

    /// Keyboard and trackpad are handled with local `NSEvent` monitors rather
    /// than SwiftUI modifiers. This gives one unambiguous place to decide whether
    /// a keystroke means "navigate" or "type into the filter" — no focus
    /// juggling, and no hidden text field stealing the arrow keys.
    private func installMonitors() {
        // `onAppear` can fire again when the window is re-ordered front without a
        // matching `onDisappear`. A second set of monitors would handle every
        // keystroke twice — arrow keys jumping two cards at a time.
        guard monitors.isEmpty else { return }

        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isDeckEvent(event) else { return event }
            return handleKey(event) ? nil : event
        }

        // Double-click opens the centred card, and it has to keep doing that once
        // the peek is up. The peek covers the deck with a renderer — `PDFView`,
        // `QLPreviewView` — that is a real AppKit view and swallows clicks before
        // any SwiftUI gesture layered over it can see them, so there is no tap
        // modifier to attach. Reading the click here, where the deck already
        // reads keys and scrolls, is both the reliable place and the consistent
        // one. Only a double-click is taken: single clicks still reach the
        // renderer for text selection, video controls and the scrim's tap-to-close.
        let clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard isDeckEvent(event), isPeeking, event.clickCount == 2 else { return event }
            if let item = currentItem { open(item) }
            return nil
        }

        let scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isDeckEvent(event) else { return event }
            // While peeking, a swipe belongs to the document — that is how a
            // multi-page preview is read. Swallowing it here left the peek
            // unscrollable, since the renderer never saw the gesture at all.
            guard !isPeeking else { return event }
            handleScroll(event)
            return nil
        }

        monitors = [keyMonitor, clickMonitor, scrollMonitor].compactMap { $0 }
    }

    /// Local monitors are installed for the whole *application*, not for one
    /// window, and ordering a window out does not fire `onDisappear` — so
    /// unscoped monitors stayed live even while the deck was hidden. The
    /// Settings window could not be scrolled and its hotkey recorder could not
    /// be typed into, because this view was quietly eating both and appending
    /// the keystrokes to an invisible filter string.
    private func isDeckEvent(_ event: NSEvent) -> Bool {
        event.window is DeckWindow
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// Keys that move through a document rather than through the deck. While
    /// peeking these are passed to the renderer, which is already the first
    /// responder, so the same keys page a PDF that would otherwise scrub the rail.
    private static let documentNavigationKeys: Set<Int> = [
        kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow,
        kVK_PageUp, kVK_PageDown, kVK_Home, kVK_End,
    ]

    /// Returns true when the event was consumed.
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            // ⌫ is read by key code: with Command held, the character AppKit
            // reports for it is a control code rather than a letter, so it
            // never reaches the switch below.
            if Int(event.keyCode) == kVK_Delete {
                if event.modifierFlags.contains(.shift) {
                    confirmClearMenu()
                } else if !filterText.isEmpty {
                    withAnimation { filterText = "" }
                }
                return true
            }

            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": performUndo(); return true
            case "p": if let item = currentItem { store.togglePin(item) }; return true
            case "r": reload(); return true
            case "w": controller.hide(); return true
            case ",": SettingsWindowController.shared.show(); return true
            default: return false
            }
        }

        if isPeeking, Self.documentNavigationKeys.contains(Int(event.keyCode)) {
            return false
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            if isPeeking { isPeeking = false }
            else if !filterText.isEmpty { withAnimation { filterText = "" } }
            // Backs out of a sub-deck before it dismisses the whole window: one
            // level at a time is what Escape means everywhere else.
            else if drillDown != nil { popDrillDown() }
            else { controller.hide() }
            return true

        case kVK_DownArrow:
            if let item = currentItem { drillInto(item) }
            return true

        case kVK_LeftArrow:  move(by: -1); return true
        case kVK_RightArrow: move(by: 1); return true
        case kVK_Home:       select(0); return true
        case kVK_End:        select(items.count - 1); return true

        case kVK_UpArrow:
            // Mirrors the upward flick exactly: inside a sub-deck it backs out,
            // and in the main deck it forgets the centred card.
            //
            // It used to clear macOS's own Recent Items system-wide instead —
            // an irreversible change to the system, on the bare arrow key next
            // to the two that merely move between cards, and meaning something
            // entirely different from what the same direction means as a
            // gesture on the same card. The confirmation sheet defended it, but
            // a key you have to be talked out of several times a day is the
            // wrong key. Clearing the menu is now ⇧⌘⌫, which nobody presses by
            // accident while browsing.
            if drillDown != nil {
                popDrillDown()
            } else if let item = currentItem {
                flick(item)
            }
            return true

        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let item = currentItem { open(item) }
            return true

        case kVK_Space:
            // Space always peeks, even mid-filter. It used to type a space into
            // the filter instead, which meant the one gesture you want after
            // finding a document — look at it — was the one you could not make.
            // Nothing is lost: the filter is a subsequence match, so "assessment4"
            // finds "Assessment 4 Report" without needing the space at all.
            isPeeking.toggle()
            return true

        case kVK_Delete:
            if !filterText.isEmpty {
                withAnimation { _ = filterText.removeLast() }
            }
            return true

        default:
            break
        }

        // Any other printable character starts or extends the filter.
        if let characters = event.charactersIgnoringModifiers,
           characters.count == 1,
           let scalar = characters.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(scalar) {
            withAnimation { filterText.append(characters) }
            return true
        }

        return false
    }

    private func handleScroll(_ event: NSEvent) {
        guard !items.isEmpty, !isPeeking else { return }

        if handleVerticalSwipe(event) { return }

        // Horizontal scroll scrubs the rail; a vertical-dominant gesture counts
        // too, so a plain two-finger swipe works whichever way the user's
        // "natural scrolling" is configured.
        let dx = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY

        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.011 : 0.09
        var proposed = scrollPosition - dx * sensitivity

        if isCircular {
            // Left free to run past either end; `delta(for:)` wraps it back.
            scrollPosition = proposed
        } else {
            proposed = min(max(proposed, 0), CGFloat(items.count - 1))
            scrollPosition = proposed
        }

        // Selection follows the rail, so Return always opens what is centred.
        let nearest = normalizedIndex(Int(scrollPosition.rounded()))
        if nearest != selectedIndex { selectedIndex = nearest }

        if event.phase == .ended || event.momentumPhase == .ended {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                scrollPosition = scrollPosition.rounded()
            }
        }
    }

    /// A two-finger trackpad swipe straight down expands the centred
    /// application card; straight up backs out of a sub-deck.
    ///
    /// This has to share the wheel with the rail, which already treats a
    /// *loosely* vertical swipe as scrubbing so that two-finger scrolling works
    /// whichever way "natural scrolling" is set. So the bar here is deliberately
    /// higher than "mostly vertical": the gesture must be strongly vertical,
    /// travel a real distance, and land on a card that actually expands.
    /// Anything short of that falls through and scrubs exactly as before.
    ///
    /// Returns true when the swipe was consumed.
    private func handleVerticalSwipe(_ event: NSEvent) -> Bool {
        // Trackpads and Magic Mouse only. A wheel notch is not a swipe, and it
        // reports no gesture phase to bound the accumulation with.
        guard event.hasPreciseScrollingDeltas else { return false }

        // Momentum is the tail of a gesture that already had its chance.
        guard event.momentumPhase == [] else { return verticalSwipeHandled }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            verticalSwipeTravel = 0
            verticalSwipeHandled = false
        }
        if verticalSwipeHandled { return true }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard abs(dy) > abs(dx) * 2.5 else { return false }

        // Consumed from here on, whatever it turns out to mean.
        //
        // A strongly vertical swipe no longer scrubs the rail. It used to fall
        // through when it had nothing to do, which is why swiping *up* slid the
        // deck sideways: the rail deliberately treats a vertical-dominant
        // gesture as scrubbing. One axis, one meaning — vertical moves between
        // levels, horizontal moves along the rail. A loosely vertical or
        // diagonal swipe is below the 2.5× bar above and still scrubs, so
        // ordinary two-finger scrolling is untouched.
        verticalSwipeTravel += dy
        guard abs(verticalSwipeTravel) > 45 else { return true }
        verticalSwipeHandled = true

        // Physical finger direction. "Natural scrolling" inverts the sign of
        // the delta, and this gesture is described to the user as a swipe of
        // the fingers, not of the content.
        let swipingDown = event.isDirectionInvertedFromDevice
            ? verticalSwipeTravel > 0
            : verticalSwipeTravel < 0

        if swipingDown {
            if drillDown == nil, let item = currentItem, canDrillInto(item) {
                drillInto(item)
            }
        } else if drillDown != nil {
            popDrillDown()
        }

        return true
    }

    /// Maps a possibly out-of-range rail position onto a real item index.
    private func normalizedIndex(_ raw: Int) -> Int {
        rail.normalizedIndex(raw)
    }
}

// MARK: - Supporting views

/// A transient line in the footer, in place of the key hints.
///
/// Two kinds share it: a flick, which can still be taken back, and the result of
/// an action that reached outside the deck and cannot be. `Equatable` so a notice
/// only dismisses itself if it is still the one on screen.
private struct DeckNotice: Equatable {
    let text: String
    let isUndoable: Bool
}

private struct KeyHintBar: View {

    @Environment(\.deckPalette) private var palette

    /// Inside an application's own recents, three of these keys mean something
    /// different — `↑` backs out rather than clearing the system menu, and `↩`
    /// opens through the owning app. A legend that still advertised the deck's
    /// bindings would be describing a screen the user is not on.
    var isDrilledIn = false
    /// Shown only when the centred card can actually expand, so the deck never
    /// advertises a gesture that would do nothing on the card in front of you.
    var canDrillDown = false

    var body: some View {
        HStack(spacing: 12) {
            if isDrilledIn {
                hint("←→", "Browse")
                hint("↩", "Open in app")
                hint("↑", "Back")
                hint("Space", "Peek")
                note("Type to filter")
                hint("⎋", "Back")
            } else {
                hint("←→", "Browse")
                hint("↩", "Open")
                if canDrillDown { hint("↓", "App recents") }
                hint("↑", "Forget")
                hint("Space", "Peek")
                note("Type to filter")
                hint("⌘,", "Settings")
                hint("⎋", "Close")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        // Without this the row compresses to fit and truncates its own labels
        // ("Type" became "Ty…") rather than simply taking the width it needs.
        .fixedSize(horizontal: true, vertical: false)
        // One glass pass for the whole row: seven separate pieces of glass in a
        // line is both slower to render and visually noisier than one grouped
        // set that blends where the pills come close.
        .deckGlassGroup(spacing: 6, palette: palette)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .deckSurface(.chip, in: RoundedRectangle(cornerRadius: 5), palette: palette)
            Text(label)
        }
    }

    /// A hint with no single key behind it.
    ///
    /// Filtering is not bound to a key, it is what *any* letter does — so
    /// drawing "Type" in a key chip beside the word "Filter" put a keycap on a
    /// key that does not exist and read as the two-word phrase "Type Filter".
    /// It is an instruction, so it is set as one.
    private func note(_ label: String) -> some View {
        Text(label).italic()
    }
}

/// Memoises one fuzzy-filter pass across the many reads a single body
/// evaluation makes.
///
/// A reference type held in `@State` so it survives the struct being rebuilt on
/// every redraw, which is precisely the thing that made the recomputation
/// repeat. The source array is compared rather than fingerprinted: a deck is
/// tens of items, and a field-by-field comparison of that is orders of magnitude
/// below the scored filter it replaces.
///
/// The comparison is `hasSameContent`, not `==`. `RecentItem` equality is
/// identity by URL, so a refresh that pins the front card or refreshes its
/// timestamp produces a list `==` to the one cached — and the deck went on
/// drawing the values from before the pin for as long as a filter was up.
private final class FilterCache {

    private var query: String?
    private var source: [RecentItem] = []
    private var result: [RecentItem] = []

    func items(matching query: String, in source: [RecentItem]) -> [RecentItem] {
        if self.query == query, self.source.hasSameContent(as: source) { return result }
        self.query = query
        self.source = source
        result = FuzzyFilter.apply(query, to: source)
        return result
    }
}

