import Foundation

/// The two pieces of state that are ours rather than the system's: which items
/// the user pinned, and which they flicked away.
///
/// Why suppression lives here instead of touching the system lists: there is no
/// supported API to remove a single entry from macOS's recent items, and
/// `sharedfilelistd` owns those files in memory — writes to them get clobbered
/// or corrupt the user's real lists. So "flick away to forget" is authoritative
/// for *this* deck and deliberately does not claim to purge the Apple menu.
///
/// Emptying the lists *entirely* is a different matter and is a real system
/// change — see `AppleMenuRecents`, which is what ↑ does. Nothing here is
/// involved in it: suppressions are this app's opinion about macOS's lists, not
/// a copy of them.
final class UserState {

    /// One flick, and the moment it happened.
    ///
    /// The date is the whole point. A flick means "not this, not now" — and an
    /// undated one outlives every later use of the item, so an app forgotten
    /// once stays invisible even while it is running in front of you and macOS
    /// itself has put it back at the top of its own recent list. That is a
    /// permanent blocklist, which is not what the gesture promises.
    private struct Suppression: Codable {
        var path: String
        var at: Date
    }

    private struct Payload: Codable {
        var pinned: [String] = []
        var suppressed: [Suppression] = []
    }

    /// The undated shape written by earlier builds, still on disk for anyone who
    /// ran one. Read once and migrated — see `load()`.
    private struct LegacyPayload: Codable {
        var pinned: [String] = []
        var suppressed: [String] = []
    }

    private var payload = Payload()
    private let fileURL: URL

    /// Most recent flick, kept in memory only so `⌘Z` can put the card back.
    /// Deliberately not persisted — undo should not survive a relaunch.
    private(set) var lastSuppressed: URL?

    /// - Parameter directory: where `state.json` lives. Injectable so the pin,
    ///   flick and migration rules can be tested against a scratch directory —
    ///   a test that used the default would be editing the pins of whoever ran
    ///   it, and would see their leftovers on the way in.
    init(directory: URL? = nil) {
        let support = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Recents", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("state.json")
        load()
    }

    // MARK: - Queries

    func isPinned(_ url: URL) -> Bool { payload.pinned.contains(url.path) }

    /// True when the user flicked this away and nothing has happened since to
    /// overrule that.
    ///
    /// `usedAt` is the newest evidence of use the caller has — a Spotlight
    /// `kMDItemLastUsedDate`, or an application's launch date. Evidence newer
    /// than the flick supersedes it: the user forgot the item, then used it
    /// again, and the second act is the more recent statement of intent. The
    /// entry is dropped rather than merely ignored, because a spent flick that
    /// stays on disk would silently hide the item again the moment its
    /// timestamps went stale.
    ///
    /// Callers with no timestamp to offer (servers, documents Spotlight has
    /// never indexed) pass nothing, and the flick stands as before.
    func isSuppressed(_ url: URL, usedAt: Date? = nil) -> Bool {
        guard let index = payload.suppressed.firstIndex(where: { $0.path == url.path })
        else { return false }

        if let usedAt, usedAt > payload.suppressed[index].at {
            payload.suppressed.remove(at: index)
            if lastSuppressed == url { lastSuppressed = nil }
            // Coalesced, not written here. This reads like a predicate but it is
            // called from inside the filter loops in `loadApplications` and
            // `loadDocuments`, so a single refresh can retire several expired
            // flicks — and a synchronous JSON encode and atomic write for each
            // one, on the main thread. The prune itself is right; doing it once
            // per pass instead of once per entry is all that changes.
            scheduleSave()
            return false
        }
        return true
    }

    /// Pin order is meaningful — pinned items hold the front of the deck in the
    /// order they were pinned.
    func pinnedRank(_ url: URL) -> Int? {
        payload.pinned.firstIndex(of: url.path)
    }

    // MARK: - Mutations

    func togglePin(_ url: URL) {
        if let index = payload.pinned.firstIndex(of: url.path) {
            payload.pinned.remove(at: index)
        } else {
            payload.pinned.append(url.path)
            // Pinning something you had previously flicked away should bring it
            // back, otherwise the pin silently does nothing.
            payload.suppressed.removeAll { $0.path == url.path }
        }
        save()
    }

    func suppress(_ url: URL) {
        guard !isSuppressed(url) else { return }
        payload.suppressed.append(Suppression(path: url.path, at: Date()))
        payload.pinned.removeAll { $0 == url.path }
        lastSuppressed = url
        save()
    }

    /// Undo the last flick. Returns the restored URL so the UI can re-select it.
    @discardableResult
    func undoSuppress() -> URL? {
        guard let url = lastSuppressed else { return nil }
        payload.suppressed.removeAll { $0.path == url.path }
        lastSuppressed = nil
        save()
        return url
    }

    func clearSuppressions() {
        payload.suppressed.removeAll()
        lastSuppressed = nil
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }

        if let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = decoded
            return
        }

        // An undated file from an earlier build. Every flick in it happened at
        // or before the file was last written, so that date is the latest any of
        // them can be — which is the conservative choice: it keeps old flicks
        // standing until the item is genuinely used again, rather than
        // resurrecting the whole list at once.
        guard let legacy = try? JSONDecoder().decode(LegacyPayload.self, from: data) else {
            quarantineUnreadableFile()
            return
        }
        let flickedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        payload = Payload(
            pinned: legacy.pinned,
            suppressed: legacy.suppressed.map { Suppression(path: $0, at: flickedAt) }
        )
        save()
    }

    /// Moves a `state.json` that decoded as neither shape out of the way.
    ///
    /// Reaching here means the file exists, holds something, and holds nothing
    /// this build can read — while the payload in memory is still the empty one
    /// this object starts with. Left where it is, the next pin or flick calls
    /// `save()`, which writes that empty payload straight over it: every pin and
    /// every flick the user ever made, gone, with nothing said at the time and
    /// nothing left to recover from. The write is atomic, so this is a narrow
    /// case rather than an impossible one — it takes damage under the file
    /// system or another process editing the file, not an interrupted save.
    ///
    /// The bytes are kept rather than reported. There is nowhere good to report
    /// it from: this runs inside `init`, long before there is a window to say it
    /// in. A file sitting beside the live one is at least an answer to "where
    /// did my pins go" rather than silence.
    private func quarantineUnreadableFile() {
        let quarantine = fileURL.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: quarantine)
        try? FileManager.default.moveItem(at: fileURL, to: quarantine)
    }

    private func save() {
        saveScheduled = false
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private var saveScheduled = false

    /// Collapses the writes from one refresh pass into a single write on the
    /// next runloop turn.
    ///
    /// Only the pruning in `isSuppressed` uses this. Deliberate user actions —
    /// pinning, flicking away, undoing — still write synchronously: those are
    /// worth a millisecond to be certain they survive a quit that lands in the
    /// same breath as the gesture. A prune that is lost that way costs nothing,
    /// since it is recomputed from the same timestamps on the next refresh.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.saveScheduled else { return }
            self.save()
        }
    }
}
