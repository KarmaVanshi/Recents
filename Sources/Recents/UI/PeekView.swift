import AppKit
import PDFKit
import Quartz
import SwiftUI

/// Full-document preview, shown on Space.
///
/// The brief asked to "peek whole file… instead of just showing the fraction of
/// it". The card thumbnails are aspect-*filled*, so they crop — fine for a card,
/// wrong for a peek. This embeds the real renderer, which shows the actual
/// document with paging, exactly like Finder's Quick Look.
///
/// A multi-page document is read by swiping, not by aiming at a scroll bar. The
/// scrollers are hidden in both renderers and replaced by two ambient cues: a
/// page counter for documents that can report one, and a thin progress rail for
/// documents that cannot. Trackpad swipes, the scroll wheel, and the arrow and
/// page keys all drive the same underlying scroll, so the gesture is the
/// interface and the rail is only ever feedback.
///
/// This became possible only once the deck moved from a `.screenSaver`-level
/// panel to an ordinary window: at panel level, QuickLook and the panel fought
/// over key-window status and the preview flickered or trapped focus.
struct PeekView: View {

    let item: RecentItem
    let onClose: () -> Void

    /// Set once PDFKit has parsed the file. Non-PDFs stay nil and fall through
    /// to QuickLook, which renders far more formats but reports no page count.
    @State private var pdf: PDFDocument?
    @State private var pageCount = 0
    @State private var currentPage = 1
    @State private var scroll = ScrollState()
    @State private var hasScrolled = false

    @Environment(\.deckPalette) private var palette

    private var isMultiPage: Bool { pageCount > 1 }

    /// True when there is more document than fits — the case the swipe hint is
    /// for. A one-page PDF and a short text file both answer false.
    private var isScrollable: Bool { isMultiPage || scroll.canScroll }

    var body: some View {
        ZStack {
            // Frosted rather than opaque, so the deck stays faintly visible
            // behind the preview and the peek reads as a layer rather than a
            // different screen.
            Rectangle()
                .fill(palette.peekScrim)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 12) {
                header
                previewSurface
                footer
            }
            .padding(22)
        }
        .task(id: item.url) { loadDocument() }
        .onChange(of: scroll.progress) { _, new in
            if new > 0.001 { hasScrolled = true }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            if let app = item.owningApp {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable().frame(width: 22, height: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.subtitle)
                    if isMultiPage { Text("· \(pageCount) pages") }
                    if let size = fileSize { Text("· \(size)") }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close preview")
        }
    }

    private var footer: some View {
        Group {
            if isScrollable {
                Text("Swipe to read · ↑↓ to page · ⎋ to close")
            } else {
                Text("Space or ⎋ to close · ↩ to open")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }

    // MARK: - The document

    private var previewSurface: some View {
        Group {
            if item.kind == .application {
                // QuickLook has nothing useful to say about an .app bundle, so
                // show the captured window at full size.
                applicationPreview
            } else if let pdf {
                PDFPreview(document: pdf, currentPage: $currentPage, scroll: $scroll)
            } else {
                QuickLookPreview(url: item.url, scroll: $scroll)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        // The two swipe affordances, layered over the document itself rather
        // than taking space from it.
        .overlay(alignment: .bottom) { swipeHint }
        .overlay(alignment: .bottomTrailing) { pageCounter }
        .overlay(alignment: .trailing) { progressRail }
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }

    /// Shown until the user scrolls once, then gone for the rest of the peek.
    /// The point is to teach the gesture, not to decorate the preview.
    @ViewBuilder
    private var swipeHint: some View {
        if isScrollable && !hasScrolled {
            HStack(spacing: 7) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 12, weight: .semibold))
                Text(isMultiPage ? "Swipe up for the next page" : "Swipe up to read on")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .deckSurface(.control, in: Capsule(), palette: palette)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
            .padding(.bottom, 16)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .allowsHitTesting(false)
        }
    }

    /// Replaces the scroll bar's "where am I" job for documents that can count
    /// their own pages.
    @ViewBuilder
    private var pageCounter: some View {
        if isMultiPage {
            Text("\(currentPage) of \(pageCount)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .deckSurface(.control, in: Capsule(), palette: palette)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
                .padding(12)
                .allowsHitTesting(false)
        }
    }

    /// And for documents that cannot — a Word file, a long web archive — a hairline
    /// rail. It is deliberately not draggable: it reports position, the swipe
    /// changes it.
    @ViewBuilder
    private var progressRail: some View {
        if scroll.canScroll && !isMultiPage {
            GeometryReader { geo in
                let track = geo.size.height - 24
                let thumb = max(28, track * scroll.visibleFraction)
                Capsule()
                    .fill(Color.primary.opacity(0.28))
                    .frame(width: 3, height: thumb)
                    .offset(
                        x: 0,
                        y: 12 + (track - thumb) * scroll.progress
                    )
            }
            .frame(width: 3)
            .padding(.trailing, 7)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var applicationPreview: some View {
        if let bundleID = item.bundleID,
           let shot = AppWindowCapture.shared.image(forBundleID: bundleID) {
            Image(nsImage: shot)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ZStack {
                Color(nsColor: .controlBackgroundColor).opacity(0.6)
                VStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable().frame(width: 128, height: 128)
                    Text("No window captured yet")
                        .font(.system(size: 12, weight: .medium))
                    Text("Allow Screen Recording, then use this app once.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Loading

    private func loadDocument() {
        pdf = nil
        pageCount = 0
        currentPage = 1
        scroll = ScrollState()
        hasScrolled = false

        guard item.kind == .document else { return }
        // `PDFDocument(url:)` returns nil for anything that is not a PDF, which
        // doubles as the format test. Parsing is lazy — it reads the trailer and
        // the page tree, not the page contents.
        guard let document = PDFDocument(url: item.url) else { return }
        pdf = document
        pageCount = document.pageCount
    }

    private var fileSize: String? {
        guard let bytes = try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Scroll reporting

/// What the hidden scroll view is doing, reported up so the peek can draw its
/// own position cues.
struct ScrollState: Equatable {
    /// 0 at the top, 1 at the bottom.
    var progress: Double = 0
    /// How much of the document is on screen — the rail's thumb size.
    var visibleFraction: Double = 1
    /// False when everything already fits, which is when no cue should appear.
    var canScroll: Bool = false
}

/// Both renderers bury their content in an `NSScrollView` they do not expose.
/// Walking the view tree is the only way to reach it — and the walk has to be
/// retried, because that scroll view does not exist until the renderer has
/// finished loading something to put in it.
@MainActor
final class ScrollBridge: NSObject {

    var onChange: ((ScrollState) -> Void)?

    private weak var clipView: NSClipView?
    private var observer: NSObjectProtocol?
    private var attempts = 0

    func attach(to root: NSView) {
        guard clipView == nil else { return }

        if let scrollView = Self.firstScrollView(in: root) {
            Self.hideScrollers(scrollView)
            bind(to: scrollView)
            return
        }

        // Nothing rendered yet. QuickLook in particular takes a few hundred
        // milliseconds to hand back a view hierarchy.
        attempts += 1
        guard attempts < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak root] in
            guard let self, let root else { return }
            self.attach(to: root)
        }
    }

    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        clipView = nil
    }

    private func bind(to scrollView: NSScrollView) {
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clipView = clip

        observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.report(scrollView) }
        }

        // Report once, on the next runloop turn: a document that opens already
        // scrollable should show its cue before the user touches anything.
        //
        // Deferred rather than synchronous because `bind` is reached from
        // `makeNSView`, and `report` writes through the `@Binding` into
        // `PeekView`'s `@State` — a write to view state from inside the view
        // update that is creating the view. It looked harmless only because the
        // first report is usually `canScroll: false`, which equals the default
        // and so changes nothing; a long PDF, which already has overflow at
        // creation time, is the case that actually writes. Same one-turn hop
        // already used for `makeFirstResponder` two lines away.
        DispatchQueue.main.async { [weak self] in
            self?.report(scrollView)
        }
    }

    private func report(_ scrollView: NSScrollView) {
        // Re-asserted rather than set once — PDFKit restores its scroller when it
        // re-lays the document out, which happens on the first scroll.
        if scrollView.verticalScroller?.isHidden == false {
            Self.hideScrollers(scrollView)
        }

        guard let document = scrollView.documentView else { return }
        let visible = scrollView.contentView.bounds
        let total = document.frame.height
        let overflow = total - visible.height

        guard overflow > 1 else {
            onChange?(ScrollState(progress: 0, visibleFraction: 1, canScroll: false))
            return
        }

        // Flipped and unflipped document views count from opposite ends.
        let offset = document.isFlipped
            ? visible.origin.y
            : overflow - visible.origin.y

        onChange?(ScrollState(
            progress: min(max(offset / overflow, 0), 1),
            visibleFraction: min(max(visible.height / total, 0.05), 1),
            canScroll: true
        ))
    }

    // MARK: - View-tree surgery

    private static func firstScrollView(in root: NSView) -> NSScrollView? {
        if let scroll = root as? NSScrollView, scroll.documentView != nil { return scroll }
        for subview in root.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    /// Hiding the scrollers does not disable scrolling — the wheel, the trackpad
    /// and the arrow keys all still drive the clip view. It only removes the
    /// thing we do not want the user reaching for.
    static func hideScrollers(_ scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        // Clearing `hasVerticalScroller` alone is not enough: PDFKit hands its
        // scroll view an overlay scroller of its own, which keeps fading itself
        // back in over the page as the reader swipes.
        scrollView.verticalScroller?.isHidden = true
        scrollView.horizontalScroller?.isHidden = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.drawsBackground = false
    }
}

// MARK: - PDF

/// PDFKit rather than QuickLook for PDFs, because it is the only renderer that
/// will tell us the page count and which page is on screen — the two facts the
/// peek needs to replace a scroll bar with a page counter.
private struct PDFPreview: NSViewRepresentable {

    let document: PDFDocument
    @Binding var currentPage: Int
    @Binding var scroll: ScrollState

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        // Continuous, not paged: one uninterrupted swipe carries the reader from
        // page to page, which is the gesture people already have for documents.
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = NSColor.black.withAlphaComponent(0.18)

        context.coordinator.bind(view: view, representable: self)

        // Take focus so ↑↓, Page Up/Down and Home/End reach the document. The
        // deck's key monitor lets those through while peeking precisely so they
        // land here.
        //
        // Going to the first page is not redundant: `autoScales` re-fits the
        // document after the initial layout and leaves the view parked partway
        // in, so a peek would open on page 2 of 24 rather than at the start.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
            view.goToFirstPage(nil)
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
        }
        context.coordinator.representable = self
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var representable: PDFPreview?
        private let bridge = ScrollBridge()
        private var pageObserver: NSObjectProtocol?
        private weak var view: PDFView?

        func bind(view: PDFView, representable: PDFPreview) {
            self.view = view
            self.representable = representable

            bridge.onChange = { [weak self] state in
                self?.representable?.scroll = state
            }
            bridge.attach(to: view)

            pageObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.view,
                          let page = view.currentPage,
                          let index = view.document?.index(for: page)
                    else { return }
                    self.representable?.currentPage = index + 1
                }
            }
        }

        func unbind() {
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            pageObserver = nil
            bridge.detach()
        }
    }
}

// MARK: - Everything else

/// Wraps AppKit's `QLPreviewView` — the same renderer Finder's Quick Look uses,
/// embedded rather than presented as its own panel. It handles the formats
/// PDFKit cannot: Word, Pages, Keynote, video, source files.
private struct QuickLookPreview: NSViewRepresentable {

    let url: URL
    @Binding var scroll: ScrollState

    func makeNSView(context: Context) -> QLPreviewView {
        // .normal gives the full interactive renderer: scrolling, multi-page
        // documents, video playback. .compact strips those down.
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL

        context.coordinator.bind(view: view, representable: self)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        context.coordinator.representable = self
        if (nsView.previewItem as? NSURL) as URL? != url {
            nsView.previewItem = url as NSURL
            context.coordinator.rebind(view: nsView)
        }
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: Coordinator) {
        coordinator.unbind()
        // QLPreviewView holds a helper process alive until told otherwise.
        nsView.close()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var representable: QuickLookPreview?
        private var bridge = ScrollBridge()

        func bind(view: QLPreviewView, representable: QuickLookPreview) {
            self.representable = representable
            bridge.onChange = { [weak self] state in
                self?.representable?.scroll = state
            }
            bridge.attach(to: view)
        }

        /// A new file means a whole new view tree underneath, so the old
        /// observation is pointing at a clip view that is about to be discarded.
        func rebind(view: QLPreviewView) {
            bridge.detach()
            bridge = ScrollBridge()
            bridge.onChange = { [weak self] state in
                self?.representable?.scroll = state
            }
            bridge.attach(to: view)
        }

        func unbind() { bridge.detach() }
    }
}
