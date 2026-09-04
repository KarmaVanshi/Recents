import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// Settings: the shortcut, what the deck shows, and the two permissions.
@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    /// Set by the app delegate so a newly recorded shortcut takes effect at once.
    var onHotKeyChange: (() -> Void)?

    /// The running deck's store, so the document stepper can stop where the deck
    /// does. Set by the app delegate; nil in the offscreen render harness, which
    /// has no deck behind it and simply offers the full range.
    var store: RecentsStore?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Recents Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsView(
                store: store,
                onHotKeyChange: { [weak self] in self?.onHotKeyChange?() }
            )
        )

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {

    /// Observed rather than merely held: `availableDocumentCount` changes as the
    /// deck refreshes behind this window, and the stepper's ceiling has to move
    /// with it.
    var store: RecentsStore?

    let onHotKeyChange: () -> Void

    @State private var prefs = Preferences.shared
    @State private var isRecording = false
    @State private var hotKeyDisplay = Preferences.shared.hotKeyDisplay
    @State private var hasScreenRecording = AppWindowCapture.shared.hasPermission
    @State private var hasAccessibility = AppWindowCapture.shared.hasAccessibilityPermission
    @State private var hasFullDiskAccess = !RecentsStoreProbe.needsFullDiskAccess

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Shortcut") {
                    HStack {
                        Text("Open Recents")
                        Spacer()
                        HotKeyRecorderView(isRecording: $isRecording) { keyCode, modifiers in
                            prefs.hotKeyCode = keyCode
                            prefs.hotKeyModifiers = modifiers
                            hotKeyDisplay = prefs.hotKeyDisplay
                            isRecording = false
                            onHotKeyChange()
                        }
                        .frame(width: 130, height: 26)
                        .overlay(
                            Text(isRecording ? "Press keys…" : hotKeyDisplay)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isRecording ? Color.accentColor : .primary)
                                .allowsHitTesting(false)
                        )
                    }

                    Button("Reset to ⇧⌘Space") {
                        prefs.hotKeyCode = UInt32(kVK_Space)
                        prefs.hotKeyModifiers = UInt32(cmdKey | shiftKey)
                        hotKeyDisplay = prefs.hotKeyDisplay
                        onHotKeyChange()
                    }
                    .font(.system(size: 11))

                    toggle(
                        "Trackpad gesture",
                        subtitle: TrackpadGestureWatcher.isAvailable
                            ? "Tap the trackpad to open or close the deck. A tap, not a "
                            + "swipe: swipes already mean pages and spaces, and this "
                            + "leaves every one of them alone."
                            : "Not available on this Mac — no trackpad the app can read.",
                        get: { prefs.trackpadGesture },
                        set: { prefs.trackpadGesture = $0 }
                    )
                    .disabled(!TrackpadGestureWatcher.isAvailable)

                    if TrackpadGestureWatcher.isAvailable {
                        // A menu rather than a segmented control: five options,
                        // each named in words long enough that segments would
                        // truncate them into initials.
                        Picker("Gesture", selection: Binding(
                            get: { prefs.summonGesture },
                            set: { prefs.summonGesture = $0 }
                        )) {
                            ForEach(SummonGesture.allCases) { gesture in
                                Text(gesture.title).tag(gesture)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 280, alignment: .leading)
                        .disabled(!prefs.trackpadGesture)

                        Text(prefs.summonGesture.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // Read from the system's own trackpad settings each time
                        // this is drawn, so switching Look Up or three-finger
                        // drag on in System Settings and coming back shows the
                        // clash rather than leaving it to be discovered as a bug
                        // in this app.
                        if let conflict = prefs.summonGesture.systemConflict {
                            Text(conflict)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                section("Browsing") {
                    Toggle(isOn: Binding(
                        get: { prefs.isCircular },
                        set: { prefs.isCircular = $0 }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Loop endlessly")
                            Text("Past the last card, start again from the first.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                section("Previews") {
                    toggle(
                        "Live window previews",
                        subtitle: LiveWindowPreview.shared.isSupported
                            ? "App cards show their window as it is right now, even while "
                            + "it is minimised — so a video playing in the background keeps "
                            + "playing on the card. Only runs while this window is open."
                            : "Not available on this version of macOS. Cards show the last "
                            + "captured still instead.",
                        get: { prefs.livePreviews },
                        set: { prefs.livePreviews = $0 }
                    )
                    .disabled(!LiveWindowPreview.shared.isSupported)

                    if prefs.livePreviews && !hasScreenRecording {
                        Text("Needs Screen Recording, below.")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }

                    Divider()

                    toggle(
                        "Dock previews",
                        subtitle: DockPreviewController.isSupported
                            ? "Rest the pointer on an app's Dock icon to see live "
                            + "thumbnails of its windows, minimised ones included. "
                            + "Click one to bring that window forward."
                            : "Not available on this version of macOS.",
                        get: { prefs.dockPreviews },
                        set: { prefs.dockPreviews = $0 }
                    )
                    .disabled(!DockPreviewController.isSupported)

                    // Both permissions are genuinely required here and neither
                    // degrades into something useful: without Accessibility the
                    // Dock cannot be asked what the pointer is over, and without
                    // Screen Recording there are no pixels to show. Saying which
                    // one is missing is the difference between a setting that
                    // looks broken and one that tells the user what to do.
                    if prefs.dockPreviews, !hasAccessibility || !hasScreenRecording {
                        Text(
                            !hasAccessibility && !hasScreenRecording
                                ? "Needs Accessibility and Screen Recording, below."
                                : (hasAccessibility
                                    ? "Needs Screen Recording, below."
                                    : "Needs Accessibility, below.")
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    }
                }

                section("Appearance") {
                    Picker("", selection: Binding(
                        get: { prefs.deckAppearance },
                        set: { prefs.deckAppearance = $0 }
                    )) {
                        ForEach(DeckAppearance.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(prefs.deckAppearance.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if prefs.deckAppearance == .liquidGlass, DeckGlass.isSupported {
                        // Apple ships exactly two Liquid Glass materials, and
                        // which one suits depends on the desktop behind the deck,
                        // so this is the user's call rather than ours.
                        Picker("", selection: Binding(
                            get: { prefs.glassStyle },
                            set: { prefs.glassStyle = $0 }
                        )) {
                            ForEach(GlassStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text(prefs.glassStyle.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            ColorPicker("", selection: Binding(
                                get: { Color(nsColor: prefs.glassTint ?? .white) },
                                set: { prefs.glassTintHex = NSColor($0).deckHexString }
                            ), supportsOpacity: false)
                            .labelsHidden()

                            Text(prefs.glassTint == nil ? "Untinted" : "Tinted glass")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            Spacer()

                            if prefs.glassTint != nil {
                                Button("Remove Tint") { prefs.glassTintHex = nil }
                                    .font(.system(size: 11))
                            }
                        }
                    }

                    if prefs.deckAppearance == .solid {
                        HStack(spacing: 10) {
                            ColorPicker("", selection: Binding(
                                get: { Color(nsColor: prefs.resolvedSolidBackground) },
                                set: { prefs.solidBackgroundHex = NSColor($0).deckHexString }
                            ), supportsOpacity: false)
                            .labelsHidden()

                            Text(prefs.usesSystemSolidBackground
                                 ? "Following the system window colour"
                                 : "Custom colour")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)

                            Spacer()

                            if !prefs.usesSystemSolidBackground {
                                Button("Use System Colour") { prefs.solidBackgroundHex = nil }
                                    .font(.system(size: 11))
                            }
                        }
                    }
                }

                section("Show") {
                    toggle("Applications", get: { prefs.showApplications }, set: { prefs.showApplications = $0 })
                    toggle(
                        "Documents",
                        subtitle: prefs.showAllFiles
                            ? "Every file macOS recorded, whichever app opened it."
                            : "What you have been reading in Preview. Every other "
                            + "app's recents live behind that app's own card.",
                        get: { prefs.showDocuments }, set: { prefs.showDocuments = $0 }
                    )

                    toggle(
                        "All files",
                        subtitle: "Every app's recent documents on one rail instead "
                                + "of only Preview's, newest first. Ordered by when you "
                                + "last opened each file — no system list ranks one "
                                + "app's files against another's.",
                        get: { prefs.showAllFiles }, set: { prefs.showAllFiles = $0 }
                    )
                    .disabled(!prefs.showDocuments)
                    .padding(.leading, 20)

                    Stepper(
                        value: Binding(
                            get: { displayedDocumentLimit },
                            set: { prefs.documentLimit = $0 }
                        ),
                        in: documentStepperRange
                    ) {
                        HStack(spacing: 6) {
                            Text("Show")
                            Text("\(displayedDocumentLimit)")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            Text(displayedDocumentLimit == 1 ? "document" : "documents")
                        }
                    }
                    .disabled(!prefs.showDocuments)
                    .padding(.leading, 20)

                    if let note = availabilityNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 20)
                    }

                    toggle(
                        "Servers",
                        subtitle: "Network volumes, as listed in the Apple menu.",
                        get: { prefs.showServers }, set: { prefs.showServers = $0 }
                    )
                    toggle(
                        "Folders",
                        subtitle: "Editors register project folders as recent documents.",
                        get: { prefs.includeFolders }, set: { prefs.includeFolders = $0 }
                    )
                }

                section("Permissions") {
                    permissionRow(
                        title: "Screen Recording",
                        detail: "Reads each app's window to use as its card — as a live, "
                              + "moving preview while the deck is open, and as a still "
                              + "otherwise. Without it, apps show their icon instead.",
                        granted: hasScreenRecording,
                        action: {
                            AppWindowCapture.shared.requestPermission()
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                        }
                    )

                    permissionRow(
                        title: "Full Disk Access",
                        detail: "Reads the recent-items lists macOS keeps — the Apple "
                              + "menu's, and Preview's own — for exact ordering. Without "
                              + "it the deck shows only what is running, and no documents "
                              + "at all.",
                        granted: hasFullDiskAccess,
                        action: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") }
                    )

                    permissionRow(
                        title: "Accessibility (optional)",
                        detail: "Notices when a minimised window is restored, so its card "
                              + "refreshes instead of keeping the older screenshot.",
                        granted: hasAccessibility,
                        action: {
                            AppWindowCapture.shared.requestAccessibilityPermission()
                            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                        }
                    )
                }

                section("Maintenance") {
                    Button("Restore Forgotten Items") {
                        NotificationCenter.default.post(name: .recentsRestoreForgotten, object: nil)
                    }
                    Button("Clear Captured Window Images") {
                        AppWindowCapture.shared.clearCaptures()
                    }
                }
            }
            .padding(24)
        }
        .onAppear { refreshPermissions() }
        // The window is created once and cached, with `isReleasedWhenClosed`
        // false, so closing Settings only orders it out — the SwiftUI tree stays
        // alive and `onAppear` fires exactly once per app launch. Permissions
        // read into `@State` there would then be frozen at their launch-time
        // values: grant Accessibility in System Settings and the row would still
        // read "Grant…" until the app was quit and relaunched. Re-reading on
        // activation covers the actual flow, since coming back from System
        // Settings is precisely when this app becomes active again.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in refreshPermissions() }
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func toggle(
        _ title: String, subtitle: String? = nil,
        get: @escaping () -> Bool, set: @escaping (Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: get, set: set)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Where the document stepper stops climbing.
    ///
    /// The smaller of the preference's own range and the number of documents the
    /// deck could actually put on the rail. Asking for fifty on a machine whose
    /// recents hold twelve is a setting nothing can satisfy, and a deck that
    /// stops at twelve then reads as though it were ignoring the number above it.
    ///
    /// With the documents group switched off there is no live count to bound it
    /// with — `availableDocumentCount` is only recomputed while the deck is
    /// building documents — so the control, disabled anyway, keeps showing the
    /// number the user actually chose rather than collapsing to one.
    private var documentCeiling: Int {
        let hard = prefs.documentLimitRange.upperBound
        guard let store, prefs.showDocuments else { return hard }
        return max(min(store.availableDocumentCount, hard), prefs.documentLimitRange.lowerBound)
    }

    private var documentStepperRange: ClosedRange<Int> {
        prefs.documentLimitRange.lowerBound...documentCeiling
    }

    /// What the stepper reads: never more than the deck could show.
    ///
    /// Held down rather than written down. A stored twenty-five against a list of
    /// eight is not a mistake to correct — the list was longer when it was chosen
    /// and will be again — so the ceiling is applied to the display and the
    /// preference is left alone until the user actually moves the control.
    private var displayedDocumentLimit: Int {
        min(prefs.documentLimit, documentCeiling)
    }

    /// Says out loud why the stepper stops where it does, so a ceiling the user
    /// did not choose does not read as a bug.
    private var availabilityNote: String? {
        guard let store, prefs.showDocuments else { return nil }
        let available = store.availableDocumentCount

        if available == 0 {
            return "Nothing in that list to show right now."
        }
        if displayedDocumentLimit >= available {
            return available == 1
                ? "That is the only one there is."
                : "All \(available) there are."
        }
        return "\(available) available."
    }

    /// Re-reads all three permissions into `@State`.
    ///
    /// Screen Recording and Accessibility are cheap TCC lookups. Full Disk
    /// Access is not: `RecentsStoreProbe.needsFullDiskAccess` opens
    /// `RecentDocuments.sfl4`, runs it through `NSKeyedUnarchiver` and resolves a
    /// bookmark per entry — filesystem work, not a TCC lookup, and roughly forty
    /// times the cost of `AXIsProcessTrusted()`. Reading it straight from the
    /// view body meant paying that on every redraw, including every frame of a
    /// window resize.
    ///
    /// Activation is the right trigger for all three: returning from System
    /// Settings is exactly when any of them can have changed.
    private func refreshPermissions() {
        hasScreenRecording = AppWindowCapture.shared.hasPermission
        hasAccessibility = AppWindowCapture.shared.hasAccessibilityPermission
        hasFullDiskAccess = !RecentsStoreProbe.needsFullDiskAccess
    }

    private func permissionRow(
        title: String, detail: String, granted: Bool, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Grant…", action: action).font(.system(size: 11))
            }
        }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}

extension Notification.Name {
    static let recentsRestoreForgotten = Notification.Name("recents.restoreForgotten")
}

/// Lightweight probe so Settings can report Full Disk Access without owning a
/// whole `RecentsStore`.
enum RecentsStoreProbe {
    static var needsFullDiskAccess: Bool {
        if case .denied = SharedFileListReader.read(.recentDocuments) { return true }
        return false
    }
}

/// Captures the next keystroke and reports it as a shortcut.
///
/// This has to be an `NSView` rather than a SwiftUI key handler: it needs raw
/// `keyDown` before the responder chain turns it into text, and it must swallow
/// keys like ⌘Q that would otherwise trigger menu commands while recording.
private struct HotKeyRecorderView: NSViewRepresentable {

    @Binding var isRecording: Bool
    let onRecord: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onRecord = onRecord
        view.onRecordingChange = { isRecording = $0 }
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onRecord = onRecord
    }

    final class RecorderView: NSView {
        var onRecord: ((UInt32, UInt32) -> Void)?
        var onRecordingChange: ((Bool) -> Void)?

        private var isRecording = false {
            didSet { onRecordingChange?(isRecording); needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                         : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isRecording ? 2 : 1
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }

            if Int(event.keyCode) == kVK_Escape {
                isRecording = false
                return
            }

            let modifiers = KeyCodeNames.carbonModifiers(from: event.modifierFlags)
            // A shortcut with no modifiers would fire while the user types
            // anywhere, so require at least one.
            guard modifiers != 0 else { NSSound.beep(); return }

            onRecord?(UInt32(event.keyCode), modifiers)
            isRecording = false
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // Swallow ⌘-combinations while recording so they get captured as a
            // shortcut instead of triggering a menu command.
            guard isRecording else { return false }
            keyDown(with: event)
            return true
        }
    }
}
