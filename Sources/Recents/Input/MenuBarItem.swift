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

    /// Left click summons the deck directly — the fast path. Right click opens
    /// the menu, so the deck is never more than one click away.
    ///
    /// The absence of an event means "summon", not "do nothing". This used to
    /// `guard let event = NSApp.currentEvent else { return }`, and an activation
    /// that arrives without a mouse event behind it — VoiceOver pressing the
    /// item, or anything driving it through the accessibility API — silently did
    /// nothing at all. Only the *secondary* gesture needs to inspect the event,
    /// so that is the only thing the event is asked about.
    @objc private func buttonClicked() {
        let event = NSApp.currentEvent
        let isSecondaryClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isSecondaryClick {
            showMenu()
        } else {
            controller.toggle()
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

        // Attaching, popping, then detaching keeps left-click free to summon
        // the deck instead of always opening this menu.
        statusItem.menu = menu
        presentedMenu = menu
        statusItem.button?.performClick(nil)
        presentedMenu = nil
        statusItem.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(
            title: "Show Recent Items", action: #selector(showDeck), keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        let shortcut = NSMenuItem(
            title: "Shortcut: \(Preferences.shared.hotKeyDisplay)", action: nil, keyEquivalent: ""
        )
        shortcut.isEnabled = false
        menu.addItem(shortcut)

        menu.addItem(.separator())

        let apps = store.items.filter { $0.kind == .application }.count
        let docs = store.items.count - apps
        let count = NSMenuItem(
            title: "\(apps) apps · \(docs) files", action: nil, keyEquivalent: ""
        )
        count.isEnabled = false
        menu.addItem(count)

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

        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Recents", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
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
