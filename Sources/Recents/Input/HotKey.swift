import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey, registered through Carbon's `RegisterEventHotKey`.
///
/// Carbon is ancient but this specific API is the right tool: it is the only
/// way to get a global hotkey **without** requiring Accessibility permission.
/// The modern-looking alternative, `NSEvent.addGlobalMonitorForEvents`, forces
/// the user through a scary "control your computer" prompt in System Settings
/// just to open a list of their own recent files. Verified: this registers with
/// `status 0` and prompts for nothing.
final class HotKey {

    /// Four-char code identifying our hotkeys to the Carbon event system.
    private static let signature: OSType = 0x5243_4E54  // 'RCNT'

    private static var registry: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var hotKeyRef: EventHotKeyRef?
    private let identifier: UInt32

    var onPress: (() -> Void)?

    /// - Parameters:
    ///   - keyCode: a `kVK_*` virtual key code.
    ///   - modifiers: Carbon modifier mask (`optionKey`, `cmdKey`, …).
    init?(keyCode: UInt32, modifiers: UInt32) {
        identifier = Self.nextID
        Self.nextID += 1

        Self.installHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &hotKeyRef
        )

        guard status == noErr else { return nil }
        Self.registry[identifier] = self
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.registry.removeValue(forKey: identifier)
    }

    // MARK: - Carbon plumbing

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotKey.signature else {
                    return OSStatus(eventNotHandledErr)
                }

                // Carbon calls us on the main thread already, but the handler
                // touches AppKit so be explicit about it.
                DispatchQueue.main.async {
                    HotKey.registry[hotKeyID.id]?.onPress?()
                }
                return noErr
            },
            1, &spec, nil, &eventHandler
        )
    }
}

extension HotKey {
    /// The user's configured summon shortcut, defaulting to ⇧⌘Space.
    ///
    /// Registration fails when another app already owns the combination, which
    /// is why this is optional rather than force-unwrapped — the caller tells
    /// the user instead of leaving a dead shortcut.
    static func summon() -> HotKey? {
        let prefs = Preferences.shared
        return HotKey(keyCode: prefs.hotKeyCode, modifiers: prefs.hotKeyModifiers)
    }
}
