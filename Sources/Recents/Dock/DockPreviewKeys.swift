import AppKit
import Carbon.HIToolbox

/// The keys a Dock preview answers while it is on screen.
///
/// This is an event tap rather than an `NSEvent` monitor, and the reason is the
/// whole shape of the feature. The preview belongs to the pointer: it appears on
/// hover, its panel never becomes key, and this app never activates — so the
/// frontmost application is still whatever the user was working in, and every
/// keystroke is being delivered there.
///
/// That rules out both of the ordinary ways to read a key. A *local* monitor
/// only sees events delivered to this application, and while a preview is up
/// none are. A *global* monitor would see them, but cannot swallow one: → would
/// step the preview and move the insertion point in the user's editor at the
/// same time, which is worse than not answering the key at all.
///
/// A tap can decline to pass an event on, so exactly the keys the preview uses
/// are the keys the application in front does not get. Everything else is
/// returned untouched, including anything with ⌘, ⌥ or ⌃ held — ⌘← is Back in a
/// browser and this has no business eating it.
///
/// It exists only while a panel does. Starting it on show and tearing it down on
/// hide is not tidiness: a keyboard tap that outlived the thing it serves would
/// be a process reading every keystroke on the system for no reason, and this
/// one cannot, because there is nothing to keep it alive between hovers.
@MainActor
final class DockPreviewKeys {

    /// What the preview understands. Deliberately short: a preview is a glance,
    /// and every key taken here is a key taken away from the app in front.
    enum Key {
        case previous
        case next
        case activate
        case dismiss
    }

    /// Handles a key and says whether it was used. Only a key that was used is
    /// withheld from the application in front.
    var onKey: ((Key) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// Whether the tap can be created at all. Event taps need Accessibility,
    /// which this feature already requires for reading the Dock — so there is
    /// no case where previews work and this does not.
    static var isSupported: Bool { AXIsProcessTrusted() }

    func start() {
        guard tap == nil else { return }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let keys = Unmanaged<DockPreviewKeys>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { keys.handle(type: type, event: event) }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
    }

    // MARK: - Reading

    private func handle(
        type: CGEventType, event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The system switches a tap off if its callback ever takes too long, and
        // says so by sending it this. Without turning it back on the preview
        // would answer keys until the machine was briefly busy and then silently
        // stop for the rest of the session.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, let key = Self.key(for: event) else {
            return Unmanaged.passUnretained(event)
        }
        guard onKey?(key) == true else { return Unmanaged.passUnretained(event) }
        return nil
    }

    private static func key(for event: CGEvent) -> Key? {
        // Any modifier means the keystroke was aimed at the application in
        // front — ⌘← is Back, ⌥← is a word left — so it is not ours to read.
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        guard event.flags.intersection(modifiers).isEmpty else { return nil }

        switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
        case kVK_LeftArrow:  return .previous
        case kVK_RightArrow: return .next
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: return .activate
        case kVK_Escape:     return .dismiss
        default:             return nil
        }
    }
}
