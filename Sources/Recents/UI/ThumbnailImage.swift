import AppKit
import SwiftUI

/// A card's preview image.
///
/// Paints the file's icon immediately and swaps in the real QuickLook render
/// when it arrives. This ordering is the whole trick behind the overlay feeling
/// instant: waiting on QuickLook before showing anything would stall the summon
/// by a visible fraction of a second on a cold cache.
///
/// The render is requested at the card's *physical* pixel size — its point size
/// times the backing scale of the screen it is actually on — and then drawn
/// aspect-fitted and never enlarged past its own resolution. Between them those
/// two rules are what keep a preview sharp: the first asks QuickLook for enough
/// pixels, and the second stops the ones it declined to give from being stretched.
struct ThumbnailImage: View {

    let url: URL
    let size: CGSize

    @Environment(\.deckPalette) private var palette

    @State private var image: NSImage?

    /// Folders get icon treatment, never a filled preview. QuickLook happily
    /// returns a folder icon for a directory, but stretching it edge-to-edge
    /// turns the deck into a wall of giant blue folders — and folders are common
    /// at the top of the list, since editors record project directories as
    /// recent items.
    private var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var body: some View {
        ZStack {
            if isDirectory {
                iconTreatment(NSWorkspace.shared.icon(forFile: url.path), scale: 0.44)
            } else if let image {
                // The ground stays behind the preview because aspect-fitting
                // letterboxes anything whose proportions differ from the card,
                // which is most documents.
                DeckSurfaceLayer(.card, in: Rectangle())
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: displaySize(for: image).width,
                        height: displaySize(for: image).height
                    )
                    .transition(.opacity)
            } else {
                iconTreatment(NSWorkspace.shared.icon(forFile: url.path), scale: 0.38)
            }
        }
        .animation(.easeOut(duration: 0.22), value: image != nil)
        .task(id: url) {
            guard !isDirectory else { return }
            await load()
        }
    }

    /// How large to draw a rendered thumbnail.
    ///
    /// Fit, never fill: cropping a page to the card's proportions cuts off the
    /// very content that makes the preview recognisable. And never past 1:1 —
    /// QuickLook substitutes a small enriched icon for file types it cannot
    /// render, and blowing a 128px icon up to fill a 300pt card is what made
    /// those cards look broken rather than deliberate.
    private func displaySize(for image: NSImage) -> CGSize {
        let native = image.size
        guard native.width > 0, native.height > 0 else { return size }
        let fit = min(size.width / native.width, size.height / native.height)
        let factor = min(fit, 1)
        return CGSize(width: native.width * factor, height: native.height * factor)
    }

    /// A centred icon on a soft frosted ground — reads as a deliberate
    /// representation rather than a failed image load, and stays of a piece with
    /// the window instead of sitting on it as an opaque panel.
    private func iconTreatment(_ icon: NSImage, scale: CGFloat) -> some View {
        ZStack {
            DeckSurfaceLayer(.card, in: Rectangle())
            LinearGradient(
                colors: [Color.primary.opacity(0.04), Color.primary.opacity(0.10)],
                startPoint: .top, endPoint: .bottom
            )
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width * scale, height: size.width * scale)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
    }

    private func load() async {
        // The screen the deck is actually on, not `NSScreen.main` — on a mixed
        // Retina/non-Retina setup those differ, and asking for the wrong one
        // means either a soft preview or twice the pixels needed.
        let scale = await MainActor.run { DeckScreen.backingScale }
        let result = await ThumbnailCache.shared.thumbnail(for: url, size: size, scale: scale)
        await MainActor.run { self.image = result }
    }
}

/// Where the deck is being drawn, for resolution decisions.
@MainActor
enum DeckScreen {
    /// Backing scale of the screen showing the deck, falling back to the screen
    /// under the pointer and then to the main display.
    static var backingScale: CGFloat {
        let window = NSApp.windows.first { $0 is DeckWindow && $0.isVisible }
        if let scale = window?.screen?.backingScaleFactor { return scale }

        let pointerScreen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }
        return pointerScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}
