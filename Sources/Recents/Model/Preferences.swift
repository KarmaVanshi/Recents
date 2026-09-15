import AppKit
import Carbon.HIToolbox
import Foundation
import Observation

/// User-configurable settings, persisted in `UserDefaults`.
///
/// Kept deliberately small: a hotkey, a few display switches. Anything the user
/// can change from the Settings window lives here and nowhere else.
///
/// These are *stored* properties that write through to `UserDefaults` on set,
/// not computed accessors over it. That distinction matters: `@Observable` only
/// instruments stored properties, so computed ones would leave every toggle in
/// Settings inert — the deck would never notice a change, because there was
/// nothing for SwiftUI to observe.
@Observable
final class Preferences {

    static let shared = Preferences()

    /// The store this instance reads and writes.
    ///
    /// Injectable so the clamping, migration and defaulting rules below can be
    /// exercised against a scratch suite. `shared` is the only instance the app
    /// ever builds, and it uses `.standard`; a test that used `.standard` would
    /// be rewriting the preferences of whoever ran it.
    @ObservationIgnored private let defaults: UserDefaults

    /// True while `init` is seeding the properties from `UserDefaults`.
    ///
    /// The `@Observable` macro rewrites stored properties into computed ones, so
    /// unlike a plain class, assignments in `init` *do* run `didSet`. Without this
    /// guard, launching would write every stored value straight back to defaults
    /// and broadcast a content change nobody asked for.
    @ObservationIgnored private var isLoading = true

    private enum Key {
        static let keyCode = "hotkey.keyCode"
        static let modifiers = "hotkey.modifiers"
        static let circular = "deck.circular"
        static let showApplications = "deck.showApplications"
        static let showDocuments = "deck.showDocuments"
        static let showServers = "deck.showServers"
        static let includeFolders = "deck.includeFolders"
        static let documentCount = "deck.documentCount"
        static let showAllFiles = "deck.showAllFiles"
        static let allFilesCount = "deck.allFilesCount"
        static let appearance = "deck.appearance"
        static let solidBackground = "deck.solidBackground"
        static let glassStyle = "deck.glassStyle"
        static let glassTint = "deck.glassTint"
        static let livePreviews = "deck.livePreviews"
        static let dockPreviews = "dock.previews"
        static let trackpadGesture = "input.trackpadGesture"
        static let summonGesture = "input.summonGesture"
        static let hasPromptedForHotKey = "onboarding.hasPromptedForHotKey"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            // ⇧⌘Space by default, per the design brief.
            Key.keyCode: Int(kVK_Space),
            Key.modifiers: Int(cmdKey | shiftKey),
            Key.circular: true,
            Key.showApplications: true,
            Key.showDocuments: true,
            Key.showServers: true,
            // Editors register their project directories as "recent documents",
            // which floods the deck with folders. The apps themselves already
            // appear as app cards, so folders are off by default.
            Key.includeFolders: false,
            Key.documentCount: Preferences.defaultDocumentCount,
            // On by default. A deck that will not show the file you had open
            // five minutes ago, because it happened to be open in Numbers, is
            // answering a question its own name does not ask — see
            // `showAllFiles`. Narrowing it back to Preview's own reading list
            // is the one the user asks for now.
            Key.showAllFiles: true,
            Key.allFilesCount: Preferences.defaultAllFilesCount,
            Key.appearance: DeckAppearance.liquidGlass.rawValue,
            Key.glassStyle: GlassStyle.regular.rawValue,
            // On by default: a card that shows a paused frame of a video that is
            // actually playing is the thing this app was reported as getting
            // wrong, and the cost only applies while the deck is open.
            Key.livePreviews: true,
            // Off by default, for the same reason the trackpad summon is: it
            // needs Accessibility, and it watches every mouse movement on the
            // system to do its job. Neither is something to switch on for
            // someone without being asked.
            Key.dockPreviews: false,
            // Off by default. It reads the trackpad through private SPI, and a
            // global input watcher is not something to switch on for someone
            // without being asked — the hotkey and the menu bar item are the
            // summoning routes that need no opting in.
            Key.trackpadGesture: false,
            Key.summonGesture: SummonGesture.default.rawValue,
            Key.hasPromptedForHotKey: false,
        ])

        // `UInt32(_:)` traps on a negative value, and this runs inside
        // `Preferences.shared`'s initialiser — so a single bad number in the
        // plist killed the app on every launch, before it could draw anything,
        // with no way back except `defaults delete` from a terminal. A corrupted
        // plist, a bad migration or a mistyped `defaults write` are all cheap to
        // survive: fall back to the registered default instead of trapping.
        hotKeyCode = UInt32(exactly: defaults.integer(forKey: Key.keyCode))
            ?? UInt32(kVK_Space)
        hotKeyModifiers = UInt32(exactly: defaults.integer(forKey: Key.modifiers))
            ?? UInt32(cmdKey | shiftKey)
        isCircular = defaults.bool(forKey: Key.circular)
        showApplications = defaults.bool(forKey: Key.showApplications)
        showDocuments = defaults.bool(forKey: Key.showDocuments)
        showServers = defaults.bool(forKey: Key.showServers)
        includeFolders = defaults.bool(forKey: Key.includeFolders)
        documentCount = Self.clamp(
            defaults.integer(forKey: Key.documentCount), to: Self.documentCountRange)
        showAllFiles = defaults.bool(forKey: Key.showAllFiles)
        allFilesCount = Self.clamp(
            defaults.integer(forKey: Key.allFilesCount), to: Self.allFilesCountRange)
        deckAppearance = defaults.string(forKey: Key.appearance)
            .flatMap(DeckAppearance.init(rawValue:)) ?? .liquidGlass
        solidBackgroundHex = defaults.string(forKey: Key.solidBackground)
        glassStyle = defaults.string(forKey: Key.glassStyle)
            .flatMap(GlassStyle.init(rawValue:)) ?? .regular
        glassTintHex = defaults.string(forKey: Key.glassTint)
        livePreviews = defaults.bool(forKey: Key.livePreviews)
        dockPreviews = defaults.bool(forKey: Key.dockPreviews)
        trackpadGesture = defaults.bool(forKey: Key.trackpadGesture)
        summonGesture = defaults.string(forKey: Key.summonGesture)
            .flatMap(SummonGesture.init(rawValue:)) ?? .default
        hasPromptedForHotKey = defaults.bool(forKey: Key.hasPromptedForHotKey)

        isLoading = false
    }

    // MARK: - Hotkey

    var hotKeyCode: UInt32 = 0 {
        didSet { persist(Int(hotKeyCode), forKey: Key.keyCode) }
    }

    var hotKeyModifiers: UInt32 = 0 {
        didSet { persist(Int(hotKeyModifiers), forKey: Key.modifiers) }
    }

    /// Human-readable shortcut, e.g. "⇧⌘Space".
    var hotKeyDisplay: String {
        KeyCodeNames.describe(keyCode: hotKeyCode, carbonModifiers: hotKeyModifiers)
    }

    // MARK: - Deck behaviour

    /// When on, the rail wraps: scrolling past the last card returns to the first.
    var isCircular: Bool = true {
        didSet { persist(isCircular, forKey: Key.circular) }
    }

    var showApplications: Bool = true {
        didSet { persist(showApplications, forKey: Key.showApplications, rebuildsDeck: showApplications != oldValue) }
    }

    var showDocuments: Bool = true {
        didSet { persist(showDocuments, forKey: Key.showDocuments, rebuildsDeck: showDocuments != oldValue) }
    }

    /// The Apple menu's third Recent Items list: network volumes.
    var showServers: Bool = true {
        didSet { persist(showServers, forKey: Key.showServers, rebuildsDeck: showServers != oldValue) }
    }

    var includeFolders: Bool = false {
        didSet { persist(includeFolders, forKey: Key.includeFolders, rebuildsDeck: includeFolders != oldValue) }
    }

    /// How many document cards the main deck carries.
    ///
    /// The main deck's documents are the ones read through Preview and nothing
    /// else — every other app's recents live in that app's own sub-deck, one
    /// swipe away — so this is a small number by nature: seven is about a
    /// morning's reading, and the rail stays short enough to scan at a glance.
    /// Clamped rather than trusted, because it is read back out of a plist that
    /// a `defaults write` can put anything into.
    var documentCount: Int = Preferences.defaultDocumentCount {
        didSet {
            let clamped = Self.clamp(documentCount, to: Self.documentCountRange)
            guard clamped == documentCount else {
                documentCount = clamped
                return
            }
            persist(documentCount, forKey: Key.documentCount, rebuildsDeck: documentCount != oldValue)
        }
    }

    static let defaultDocumentCount = 7
    static let documentCountRange = 1...25

    /// When on — which is now the default — the main deck's documents are every
    /// file macOS recorded, whichever app opened it. Off, they are only the ones
    /// read in Preview.
    ///
    /// The narrow reading had a real argument behind it: every other app's
    /// recents already sit one swipe behind that app's own card, so a flat list
    /// of all of them says the same thing twice, and says it without
    /// attribution. What that argument left out is that the swipe has to be
    /// *known about* to be used. A deck called Recents that will not simply show
    /// you the file you had open five minutes ago — because it happened to be
    /// open in Numbers — is answering a question its own name does not ask, and
    /// no amount of correctness one card-swipe away makes up for it.
    ///
    /// It changes the *source* rather than loosening a filter: on, the deck
    /// reads every per-app list unioned with the Apple menu's global
    /// `RecentDocuments.sfl4` and orders the result by when each file was last
    /// used. See `RecentsStore.mergedDocumentOrder` for why the global list
    /// alone is not enough, and why a timestamp order is the only one that
    /// exists across apps. That order is the price of the wider deck, and it is
    /// declared rather than hidden: those cards are marked `.spotlight`, and
    /// `--parity` reports them as unchecked instead of quietly passing them.
    var showAllFiles: Bool = true {
        didSet { persist(showAllFiles, forKey: Key.showAllFiles, rebuildsDeck: showAllFiles != oldValue) }
    }

    /// How many document cards the main deck carries while `showAllFiles` is on.
    ///
    /// Stored separately from `documentCount`, rather than sharing it with a
    /// wider range, because the two numbers answer different questions. Seven is
    /// a morning's reading; the all-files rail is a day's work across every app,
    /// and clamping one into the other's range on every toggle would silently
    /// throw the user's choice away each time they switched back.
    var allFilesCount: Int = Preferences.defaultAllFilesCount {
        didSet {
            let clamped = Self.clamp(allFilesCount, to: Self.allFilesCountRange)
            guard clamped == allFilesCount else {
                allFilesCount = clamped
                return
            }
            persist(allFilesCount, forKey: Key.allFilesCount, rebuildsDeck: allFilesCount != oldValue)
        }
    }

    static let defaultAllFilesCount = 25
    static let allFilesCountRange = 1...100

    /// The cap the deck actually applies, and the range the stepper offers —
    /// whichever pair the active source calls for. Both are computed over stored
    /// properties, so reading either one from a view body still registers the
    /// observation that a `UserDefaults`-backed accessor would have lost.
    var documentLimit: Int {
        get { showAllFiles ? allFilesCount : documentCount }
        set { if showAllFiles { allFilesCount = newValue } else { documentCount = newValue } }
    }

    var documentLimitRange: ClosedRange<Int> {
        showAllFiles ? Self.allFilesCountRange : Self.documentCountRange
    }

    /// Clamped rather than trusted, because these are read back out of a plist
    /// that a `defaults write` can put anything into.
    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    var hasPromptedForHotKey: Bool = false {
        didSet { persist(hasPromptedForHotKey, forKey: Key.hasPromptedForHotKey) }
    }

    // MARK: - Appearance

    /// Glass or solid. Changing it has to reach the `NSWindow` — see
    /// `DeckAppearance` — so it broadcasts rather than relying on observation.
    var deckAppearance: DeckAppearance = .liquidGlass {
        didSet {
            persist(
                deckAppearance.rawValue, forKey: Key.appearance,
                redrawsWindow: deckAppearance != oldValue
            )
        }
    }

    /// `#RRGGBB` for the solid ground, or nil to follow the system's window
    /// background — which is the default, and the only value that tracks the
    /// user's light/dark setting on its own.
    var solidBackgroundHex: String? = nil {
        didSet {
            guard !isLoading else { return }
            if let solidBackgroundHex {
                defaults.set(solidBackgroundHex, forKey: Key.solidBackground)
            } else {
                defaults.removeObject(forKey: Key.solidBackground)
            }
            guard solidBackgroundHex != oldValue else { return }
            NotificationCenter.default.post(name: .recentsAppearanceChanged, object: nil)
        }
    }

    /// Which of Apple's two Liquid Glass styles the deck is made of. Regular is
    /// the standard material; clear is the thinner one meant to sit over
    /// media-rich content, where it lets far more of the backdrop through.
    var glassStyle: GlassStyle = .regular {
        didSet {
            persist(
                glassStyle.rawValue, forKey: Key.glassStyle,
                redrawsWindow: glassStyle != oldValue
            )
        }
    }

    /// `#RRGGBB` tint applied to the glass, or nil for untinted. Liquid Glass
    /// tints rather than fills: the colour bends the light the material is
    /// already refracting instead of painting over it.
    var glassTintHex: String? = nil {
        didSet {
            guard !isLoading else { return }
            if let glassTintHex {
                defaults.set(glassTintHex, forKey: Key.glassTint)
            } else {
                defaults.removeObject(forKey: Key.glassTint)
            }
            guard glassTintHex != oldValue else { return }
            NotificationCenter.default.post(name: .recentsAppearanceChanged, object: nil)
        }
    }

    var glassTint: NSColor? {
        glassTintHex.flatMap { NSColor(deckHexString: $0) }
    }

    // MARK: - Previews

    /// Whether application cards show a live, moving preview of the app's window
    /// — including while that window is minimized — rather than a still.
    var livePreviews: Bool = true {
        didSet {
            guard !isLoading, livePreviews != oldValue else { return }
            defaults.set(livePreviews, forKey: Key.livePreviews)
            NotificationCenter.default.post(name: .recentsLivePreviewSettingChanged, object: nil)
        }
    }

    /// Whether hovering an app's Dock tile shows live thumbnails of that app's
    /// windows, minimized ones included.
    ///
    /// The deck answers "what was I working on"; this answers "what is behind
    /// this icon", which is a different question and the one the Dock itself
    /// leaves unanswered — macOS shows an Exposé grid only after a click and
    /// hold, and shows it as stills. Same window-server path as the deck's live
    /// cards, so a video playing in a minimized window keeps playing here too.
    ///
    /// Kept separate from `livePreviews` rather than folded into it. That switch
    /// governs cost inside a window the user has deliberately opened; this one
    /// governs a global mouse watcher and an accessibility connection to the
    /// Dock that are live whenever the app is, which is a different thing to
    /// consent to.
    var dockPreviews: Bool = false {
        didSet {
            guard !isLoading, dockPreviews != oldValue else { return }
            defaults.set(dockPreviews, forKey: Key.dockPreviews)
            NotificationCenter.default.post(name: .recentsDockPreviewSettingChanged, object: nil)
        }
    }

    // MARK: - Trackpad

    /// Whether a trackpad tap summons the deck at all. Which tap is
    /// `summonGesture`.
    ///
    /// A *tap* rather than a swipe in every case, because that is the shape
    /// macOS leaves unclaimed. Swipes at every finger count already mean
    /// something — pages, spaces, Mission Control — and a summon that fired on
    /// the way into one of those would be worse than no gesture at all.
    /// Measured on the machine this was built for: across roughly forty
    /// three-finger swipe episodes the recogniser fired zero times, and eight
    /// deliberate taps all registered.
    var trackpadGesture: Bool = false {
        didSet {
            guard !isLoading, trackpadGesture != oldValue else { return }
            defaults.set(trackpadGesture, forKey: Key.trackpadGesture)
            NotificationCenter.default.post(name: .recentsTrackpadGestureChanged, object: nil)
        }
    }

    /// Which trackpad shape does the summoning.
    ///
    /// A choice rather than a constant because "unclaimed" is not a property of
    /// the gesture alone: three fingers are free on a stock Mac but not once
    /// Look Up or three-finger drag is switched on, and how easily five fingers
    /// reach a trackpad depends on the trackpad. `SummonGesture` carries what
    /// each shape costs, and reads the system's own settings to say when one of
    /// them is already taken.
    ///
    /// Shares `recentsTrackpadGestureChanged` with the switch above: both
    /// answers are applied by the same code, which rebuilds the recogniser and
    /// starts or stops the watcher to match.
    var summonGesture: SummonGesture = .default {
        didSet {
            guard !isLoading, summonGesture != oldValue else { return }
            defaults.set(summonGesture.rawValue, forKey: Key.summonGesture)
            NotificationCenter.default.post(name: .recentsTrackpadGestureChanged, object: nil)
        }
    }

    var usesSystemSolidBackground: Bool { solidBackgroundHex == nil }

    /// The colour the solid ground actually paints with. Resolved through the
    /// system colour when the user has not picked one, so it follows light and
    /// dark mode without any work on our part.
    var resolvedSolidBackground: NSColor {
        if let solidBackgroundHex, let color = NSColor(deckHexString: solidBackgroundHex) {
            return color
        }
        return .windowBackgroundColor
    }

    /// - Parameter rebuildsDeck: true for the switches that change *which items
    ///   exist* rather than how they are drawn. Those need the store to rebuild;
    ///   SwiftUI observation alone would only redraw an unchanged item list.
    /// - Parameter redrawsWindow: true for the switches the `NSWindow` itself has
    ///   to act on. SwiftUI observation cannot reach a window's opacity or
    ///   background colour, so those need a broadcast too.
    private func persist(
        _ value: Any, forKey key: String,
        rebuildsDeck: Bool = false, redrawsWindow: Bool = false
    ) {
        guard !isLoading else { return }
        defaults.set(value, forKey: key)
        if rebuildsDeck {
            NotificationCenter.default.post(name: .recentsContentPreferencesChanged, object: nil)
        }
        if redrawsWindow {
            NotificationCenter.default.post(name: .recentsAppearanceChanged, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted when a preference changes what the deck should contain.
    static let recentsContentPreferencesChanged =
        Notification.Name("recents.contentPreferencesChanged")

    /// Posted when a preference changes how the deck window itself is grounded.
    static let recentsAppearanceChanged = Notification.Name("recents.appearanceChanged")

    /// Posted when live window previews are switched on or off, so the engine
    /// can start or stop without waiting for the deck to be reopened.
    static let recentsLivePreviewSettingChanged =
        Notification.Name("recents.livePreviewSettingChanged")

    /// Posted when the trackpad summon is switched on or off, so the watcher can
    /// start or stop immediately rather than at the next launch.
    static let recentsTrackpadGestureChanged =
        Notification.Name("recents.trackpadGestureChanged")

    /// Posted when Dock previews are switched on or off, so the hover watcher
    /// starts or stops at once rather than at the next launch.
    static let recentsDockPreviewSettingChanged =
        Notification.Name("recents.dockPreviewSettingChanged")
}

/// Turns virtual key codes and Carbon modifier masks into the glyphs macOS uses
/// in menus, so a recorded shortcut reads the same here as it would in any
/// other app's preferences.
enum KeyCodeNames {

    static func describe(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        modifierGlyphs(carbonModifiers) + keyName(keyCode)
    }

    static func modifierGlyphs(_ carbonModifiers: UInt32) -> String {
        var out = ""
        // Order matches Apple's menu convention: ⌃⌥⇧⌘
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { out += "⌘" }
        return out
    }

    /// Converts AppKit's `NSEvent.modifierFlags` to the Carbon mask that
    /// `RegisterEventHotKey` expects.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func keyName(_ keyCode: UInt32) -> String {
        if let name = named[Int(keyCode)] { return name }

        // Ask the current keyboard layout what this key produces, so a recorded
        // shortcut displays correctly on non-US layouts.
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)

            let status = data.withUnsafeBytes { buffer -> OSStatus in
                guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
                else { return OSStatus(paramErr) }
                return UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeys, chars.count, &length, &chars
                )
            }

            if status == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }

        return "Key \(keyCode)"
    }
}
