import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = RecentsStore()
    private var controller: DeckWindowController!
    private var menuBar: MenuBarItem!
    private var hotKey: HotKey?
    private var trackpadObserver: NSObjectProtocol?
    private var dockPreviewObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        AppWindowCapture.shared.start()

        controller = DeckWindowController(store: store)
        menuBar = MenuBarItem(controller: controller, store: store)

        rebindHotKey()
        SettingsWindowController.shared.onHotKeyChange = { [weak self] in
            self?.rebindHotKey()
        }

        applyTrackpadGesture()
        // Toggling the setting takes effect at once rather than at the next
        // launch, which is what makes it testable from the Settings window the
        // user is standing in.
        trackpadObserver = NotificationCenter.default.addObserver(
            forName: .recentsTrackpadGestureChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTrackpadGesture() }
        }
        // Dock previews are independent of the deck: the watcher runs whenever
        // the preference is on, whether or not the deck has ever been opened.
        // Same immediate-effect treatment as the trackpad gesture, so the switch
        // can be judged from the Settings window the user is standing in.
        DockPreviewController.shared.start()
        dockPreviewObserver = NotificationCenter.default.addObserver(
            forName: .recentsDockPreviewSettingChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DockPreviewController.shared.reload() }
        }

        // Settings shows how many documents the deck could actually carry, which
        // only the live store knows.
        SettingsWindowController.shared.store = store

        NotificationCenter.default.addObserver(
            forName: .recentsRestoreForgotten, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.userState.clearSuppressions()
                self.store.refresh()
            }
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render"),
           CommandLine.arguments.count > index + 1 {
            DeckSnapshot.run(store: store, outputPath: CommandLine.arguments[index + 1])
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render-settings"),
           CommandLine.arguments.count > index + 1 {
            DeckSnapshot.runSettings(outputPath: CommandLine.arguments[index + 1])
            return
        }

        // `--show` opens the deck immediately, for development and screenshots
        // where triggering a global hotkey is awkward.
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.controller.show()
            }
        }

        if !Preferences.shared.hasPromptedForHotKey {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.runFirstRunPrompt()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        AppWindowCapture.shared.stop()
        DockPreviewController.shared.stop()
    }

    /// Registers the configured shortcut, replacing any previous one.
    /// Starts or stops the trackpad watcher to match the preference.
    ///
    /// The gesture is a second door to the same room, so it calls `toggle()` —
    /// the same entry point as the hotkey and the menu bar item — rather than
    /// growing a summoning path of its own.
    private func applyTrackpadGesture() {
        let watcher = TrackpadGestureWatcher.shared
        let gesture = Preferences.shared.summonGesture
        TrackpadGestureWatcher.log.write("applyTrackpadGesture: preference \(Preferences.shared.trackpadGesture), gesture \(gesture.title), available \(TrackpadGestureWatcher.isAvailable)")
        guard Preferences.shared.trackpadGesture, TrackpadGestureWatcher.isAvailable else {
            watcher.onGesture = nil
            watcher.stop()
            return
        }
        // Explicit, not inherited. Leaving the recogniser at its own default is
        // what made the first version of this silently unreachable — and it is
        // now also how a change of gesture reaches an already-running watcher,
        // which `start()` alone would not, since it returns early when running.
        watcher.recognizer = gesture.recognizer
        watcher.onGesture = { [weak self] in
            TrackpadGestureWatcher.log.write("gesture fired — toggling the deck")
            self?.controller.toggle()
        }
        watcher.start()
    }

    private func rebindHotKey() {
        // Dropping the old key first matters: Carbon keeps a registration alive
        // until it is unregistered, and deinit is what releases it.
        hotKey = nil

        hotKey = HotKey.summon()
        hotKey?.onPress = { [weak self] in self?.controller.toggle() }

        if hotKey == nil { warnHotKeyUnavailable() }
    }

    private func warnHotKeyUnavailable() {
        let alert = NSAlert()
        alert.messageText = "\(Preferences.shared.hotKeyDisplay) is already taken"
        alert.informativeText = """
            Another app has registered that shortcut, so Recents could not claim it.

            Pick a different one in Settings, or open the deck from the clock icon \
            in the menu bar.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            SettingsWindowController.shared.show()
        }
    }

    /// One-time welcome: states the shortcut and offers to change it, which is
    /// the "prompt the user to set their own hotkey" the brief asks for.
    private func runFirstRunPrompt() {
        Preferences.shared.hasPromptedForHotKey = true

        let alert = NSAlert()
        alert.messageText = "Recents is running"
        alert.informativeText = """
            Press \(Preferences.shared.hotKeyDisplay) anywhere to open your recent \
            apps and files. You can change the shortcut, and allow Screen Recording \
            so apps show their last window instead of an icon.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Got It")
        if alert.runModal() == .alertFirstButtonReturn {
            SettingsWindowController.shared.show()
        }
    }
}
