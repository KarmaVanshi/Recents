import AppKit
import SwiftUI

/// Renders the deck to a PNG without needing Screen Recording permission.
///
/// Development aid: `screencapture` is gated behind a TCC permission that a
/// build script has no business demanding, and a global-hotkey overlay is
/// awkward to photograph by hand. Drawing the live view hierarchy into a bitmap
/// from inside the process sidesteps both.
///
/// Caveat: the shipping window's background is glass — an `NSGlassEffectView`
/// refracting the desktop behind it — and `cacheDisplay` cannot reproduce that. It
/// would render the deck onto transparency. So the snapshot substitutes an
/// opaque stand-in ground of roughly the right value. Everything else — cards,
/// tilt, thumbnails, captions — is exactly what ships.
///
/// Run: `Recents --render /path/to/out.png`
@MainActor
enum DeckSnapshot {

    static func run(store: RecentsStore, outputPath: String) {
        let size = RenderOptions.renderSize

        let controller = DeckWindowController(store: store)
        let view = DeckView(store: store, controller: controller)

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        // In solid mode the snapshot can show the real ground, because there is
        // nothing to sample — the colour is the colour. Only glass needs a
        // stand-in, and it is labelled as one rather than passed off as accurate.
        let prefs = Preferences.shared
        let ground = RenderOptions.appearance == .solid
            ? prefs.resolvedSolidBackground
            : NSColor(calibratedWhite: 0.16, alpha: 1)

        let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = ground.cgColor
        backdrop.addSubview(hosting)

        // The view must be in a window for SwiftUI to lay out and for `.task`
        // modifiers (which load thumbnails) to fire at all.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        // The same contrast guarantee the live window makes in `applyAppearance()`
        // — without it a snapshot of a dark custom ground would be drawn with the
        // system's light-mode text, and would not represent what ships.
        if RenderOptions.appearance == .solid, !prefs.usesSystemSolidBackground {
            window.appearance = NSAppearance(
                named: ground.deckLuminance < 0.5 ? .darkAqua : .aqua
            )
        }

        window.contentView = backdrop
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))  // offscreen
        window.orderFront(nil)

        // Wait for Spotlight's gather and the first wave of QuickLook renders.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            backdrop.layoutSubtreeIfNeeded()

            guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else {
                print("could not allocate bitmap")
                exit(1)
            }
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)

            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("could not encode png")
                exit(1)
            }

            do {
                try png.write(to: URL(fileURLWithPath: outputPath))
                let note = RenderOptions.appearance == .solid
                    ? "solid ground, as shipped"
                    : "glass substituted with an opaque stand-in"
                print("wrote \(outputPath) (\(rep.pixelsWide)×\(rep.pixelsHigh), \(note))")
                exit(0)
            } catch {
                print("write failed: \(error)")
                exit(1)
            }
        }
    }

    /// Renders the Settings window offscreen.
    ///
    /// Same reasoning as the deck snapshot, plus one of its own: the Settings
    /// window is opened by a keyboard shortcut that only works while the deck is
    /// focused, which makes it awkward to photograph by driving the UI. Rendering
    /// it directly is deterministic and needs no accessibility permissions.
    ///
    /// Run: `Recents --render-settings /path/to/out.png`
    static func runSettings(outputPath: String) {
        let size = CGSize(width: 480, height: 900)

        // A real store, because the document stepper's ceiling is the number of
        // documents the deck can actually carry — rendered without one, the
        // snapshot would show a control that does not exist as shipped.
        let store = RecentsStore()
        store.start()

        let hosting = NSHostingView(rootView: SettingsView(store: store, onHotKeyChange: {}))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                print("could not allocate bitmap"); exit(1)
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("could not encode png"); exit(1)
            }
            do {
                try png.write(to: URL(fileURLWithPath: outputPath))
                print("wrote \(outputPath) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
                exit(0)
            } catch { print("write failed: \(error)"); exit(1) }
        }
    }

}