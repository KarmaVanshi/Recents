import AppKit

/// The question asked before `AppleMenuRecents.clear()`, and the sentence said
/// afterwards.
///
/// Kept in one place because the action now has two doors — ⇧⌘⌫ in the deck and
/// an item in the menu bar — and the copy is the safety feature. An action that
/// empties macOS's own lists system-wide, with no undo, is one the user should
/// meet the same warning about however they reached it; two hand-written alerts
/// drift, and the one that drifts is the one that ends up understating what is
/// about to happen.
@MainActor
enum ClearMenuPrompt {

    /// Asks, and clears if the answer is yes.
    ///
    /// - Parameter window: a window to hang the question on as a sheet, so the
    ///   deck stays visible behind the question being asked about it. Nil — the
    ///   menu bar's case, which has no window — falls back to a modal alert.
    /// - Parameter completion: the outcome as a sentence to show the user, or
    ///   nil when they cancelled. Cancelling is not an outcome worth reporting:
    ///   the user knows they cancelled.
    static func run(attachedTo window: NSWindow?, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Clear the Apple menu’s Recent Items?"
        alert.informativeText = """
            This empties macOS’s own lists of recent applications, documents and \
            servers — the ones every app’s  menu shows. It cannot be undone.

            Your document cards stay: they come from Preview’s own recents, \
            which this leaves alone. So do apps that are running right now.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Menu")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        // Return opens the centred card everywhere else in the deck. Leaving it
        // wired to the default button here is how a muscle-memory ⏎ wipes the
        // user's recent items, so Cancel takes it and Clear takes no key at all.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        let act: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(perform())
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: act)
        } else {
            act(alert.runModal())
        }
    }

    /// Clears, and reports what happened in one line.
    private static func perform() -> String {
        switch AppleMenuRecents.clear() {
        case .cleared(let entries):
            let count = entries == 1 ? "1 item" : "\(entries) items"
            return "Cleared the Apple menu’s Recent Items — \(count)"
        case .nothingToClear:
            return "The Apple menu’s Recent Items was already empty"
        case .denied:
            return "Can’t clear Recent Items — grant Full Disk Access in Settings"
        }
    }
}
