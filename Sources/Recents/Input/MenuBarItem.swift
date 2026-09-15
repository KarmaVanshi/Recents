import AppKit

/// The menu bar presence: a discoverable way in, and the place where the app
/// explains itself.
///
/// The hotkey is the primary surface, but a global shortcut nobody can see is a
/// bad only-door — this is how the user finds the app again, learns the
/// shortcut, and quits it.
@MainActor
final class MenuBarItem {

    private let statusItem: NSStatusItem
    private let controller: DeckWindowController
    private let store: RecentsStore

    init(controller: DeckWindowController, store: RecentsStore) {
        self.controller = controller
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "clock.arrow.circlepath",
                accessibilityDescription: "Recent Items"
            )
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Left click opens Settings. Right click opens the menu, which is where
    /// everything else lives — the deck included.
    ///
    /// The primary click used to summon the deck. It was moved because the deck
    /// now has a trackpad shape of its own — see `SummonGesture` — and Settings
    /// did not: reaching it meant a right click and then a menu item, which is
    /// two clicks for the one thing in this app that is looked for by pointer
    /// rather than by muscle memory. The deck is still a keystroke, a trackpad
    /// tap, and "Show Recent Items" in the menu, so nothing about it got further
    /// away than the click that was spent finding it.
    ///
    /// The absence of an event means the primary gesture, not "do nothing". This
    /// used to `guard let event = NSApp.currentEvent else { return }`, and an
    /// activation that arrives without a mouse event behind it — VoiceOver
    /// pressing the item, or anything driving it through the accessibility API —
    /// silently did nothing at all. Only the *secondary* gesture needs to inspect
    /// the event, so that is the only thing the event is asked about.
    @objc private func buttonClicked() {
        let event = NSApp.currentEvent
        let isSecondaryClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isSecondaryClick {
            showMenu()
        } else {
            openSettings()
        }
    }

    /// Where the status item is on screen, so `MenuSelfTest` can right-click it
    /// rather than reaching past the gesture and calling `showMenu` directly.
    /// Nil until the menu bar has actually placed the item.
    var buttonFrame: CGRect? {
        guard let window = statusItem.button?.window, window.frame.width > 0 else { return nil }
        return window.frame
    }

    /// The menu currently on screen, or nil. Readable while `showMenu` is
    /// blocked in menu tracking, which is the only moment there is anything to
    /// ask about — `NSMenu.highlightedItem` is how the test sees what the
    /// arrow keys did.
    private(set) var presentedMenu: NSMenu?

    private func showMenu() {
        let menu = makeMenu()

        // Attaching, popping, then detaching keeps the primary click free to
        // open Settings instead of always opening this menu.
        statusItem.menu = menu
        presentedMenu = menu
        statusItem.button?.performClick(nil)
        presentedMenu = nil
        statusItem.menu = nil
    }

    /// The menu, with every item that does something grouped together at the
    /// top and everything that merely says something at the bottom.
    ///
    /// The order is the whole point of this arrangement. A disabled row cannot
    /// take the highlight — that is AppKit's rule for every menu — so a run of
    /// them sitting between two actions is a stretch of menu the pointer travels
    /// through with nothing lighting up. Measured on the previous order, that
    /// stretch was about a hundred points tall: leaving "Show Recent Items" the
    /// highlight went out and did not come back until "Restore Forgotten Items",
    /// which reads exactly like a menu that has stopped tracking the mouse.
    ///
    /// Actions first and contiguous, so travelling from the first to the last
    /// never crosses a gap. The three informational rows go together at the
    /// bottom, where the only thing below them is Quit — which is the one item
    /// nobody should reach by accident anyway.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(
            title: "Show Recent Items", action: #selector(showDeck), keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        // Directly under the deck, and deliberately far from Quit. It used to sit
        // immediately above it, which put the app's most-used item and its most
        // destructive one one row apart.
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        if !AppWindowCapture.shared.hasPermission {
            let capture = NSMenuItem(
                title: "Allow Screen Recording…",
                action: #selector(openScreenRecordingSettings), keyEquivalent: ""
            )
            capture.target = self
            menu.addItem(capture)
        }

        if store.needsFullDiskAccess {
            let grant = NSMenuItem(
                title: "Grant Full Disk Access…", action: #selector(openPrivacySettings), keyEquivalent: ""
            )
            grant.target = self
            menu.addItem(grant)
        }

        let restore = NSMenuItem(
            title: "Restore Forgotten Items", action: #selector(restoreForgotten), keyEquivalent: ""
        )
        restore.target = self
        menu.addItem(restore)

        // Clearing macOS's own Recent Items used to be reachable only by
        // pressing ↑ in the deck, which is both the wrong key for an
        // irreversible system-wide change and no way to find it. It is a
        // system action, so it belongs where the app's other system actions
        // are; the deck keeps ⇧⌘⌫ for anyone who wants it from the keyboard.
        let clear = NSMenuItem(
            title: "Clear Apple Menu Recent Items…",
            action: #selector(clearAppleMenu), keyEquivalent: ""
        )
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        // Everything below here is a label rather than a control: the two ways
        // in that are not this menu, and what the deck currently holds.
        for title in [
            trackpadSummary,
            "Shortcut: \(Preferences.shared.hotKeyDisplay)",
            deckSummary,
        ].compactMap({ $0 }) {
            let note = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Recents", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// The trackpad shape, when there is one to report.
    private var trackpadSummary: String? {
        guard Preferences.shared.trackpadGesture, TrackpadGestureWatcher.isAvailable
        else { return nil }
        return "Trackpad: \(Preferences.shared.summonGesture.title)"
    }

    private var deckSummary: String {
        let apps = store.items.filter { $0.kind == .application }.count
        return "\(apps) apps · \(store.items.count - apps) files"
    }

    @objc private func showDeck() { controller.show() }

    @objc private func openSettings() { SettingsWindowController.shared.show() }

    @objc private func openScreenRecordingSettings() {
        AppWindowCapture.shared.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func restoreForgotten() {
        store.userState.clearSuppressions()
        store.refresh()
    }

    /// Asks first, in the same words the deck asks in — see `ClearMenuPrompt`.
    /// There is no window to hang a sheet on from a status item, so this one is
    /// modal.
    @objc private func clearAppleMenu() {
        ClearMenuPrompt.run(attachedTo: nil) { [weak self] outcome in
            guard outcome != nil else { return }
            self?.store.refresh()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
