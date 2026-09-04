import AppKit
import CoreServices
import Foundation
import Observation

/// Merges every recency source into the single ordered list the deck renders.
///
/// The shared file lists are the authority, not one input among several. They
/// are the exact files the Apple menu's Recent Items reads, and the order of
/// entries inside them *is* the order the Apple menu shows — so this class's
/// first duty is to reproduce that order rather than to improve on it.
///
/// Four sources, each covering the others' gaps:
///   • `RecentApplications.sfl4` — the apps the user actually launched, in true
///     recency order. Headline content: these become window-screenshot cards.
///   • `ApplicationRecentDocuments/com.apple.preview.sfl4` — the main deck's
///     documents, and by default the only app's documents it carries. See
///     `loadDocuments` for why the global `RecentDocuments.sfl4` does not feed
///     the main rail by default: every other app's recents are one swipe behind
///     that app's own card, so putting them in the main deck as well said the
///     same thing twice. `Preferences.showAllFiles` swaps this source for every
///     app's documents at once, for anyone who would rather have the flat rail.
///   • Spotlight — real timestamps for those documents, and the change feed that
///     tells us to look again.
///   • `OfficeRecentsReader` — Word, Excel and PowerPoint keep private MRU lists
///     and register nothing in the per-app shared lists, so an app card for one
///     of them had nothing to expand into. This feeds those sub-decks only; it
///     never touches the main deck.
///
/// Applications lead the deck, then documents, then servers. Within each group
/// the shared file list's own order is preserved exactly, and everything the
/// lists do not contain — running apps macOS has not recorded yet — is appended
/// *after* it, never interleaved into it. Sorting the authoritative entries by
/// Spotlight timestamps would produce a defensible order that simply is not the
/// Apple menu's, which is the divergence this is written to avoid.
@Observable
final class RecentsStore {

    private(set) var items: [RecentItem] = []

    /// True when a shared file list exists but refused to open — the TCC
    /// signature. Drives the Full Disk Access banner, and nothing else.
    private(set) var needsFullDiskAccess = false

    /// True when the deck's order is macOS's own. False means at least one list
    /// could not be read and part of the deck is Spotlight's best guess, which
    /// the UI says out loud rather than passing off as Apple-menu parity.
    var isAppleMenuAuthoritative: Bool { !needsFullDiskAccess }

    /// Tracked separately because either list can be denied independently, and
    /// because the banner must not keep asserting a stale answer when the group
    /// that produced it is switched off.
    @ObservationIgnored private var applicationsDenied = false
    @ObservationIgnored private var documentsDenied = false
    @ObservationIgnored private var serversDenied = false

    @ObservationIgnored let userState = UserState()
    @ObservationIgnored private let prefs = Preferences.shared

    @ObservationIgnored private let spotlight = SpotlightSource()
    @ObservationIgnored private var watchers: [FileWatcher] = []

    /// Armed only while the deck is reading the global list. See
    /// `updateGlobalDocumentsWatcher`.
    @ObservationIgnored private var globalDocumentsWatcher: FileWatcher?
    @ObservationIgnored private var spotlightDates: [URL: Date] = [:]
    @ObservationIgnored private var refreshWorkItem: DispatchWorkItem?
    @ObservationIgnored private var preferenceObserver: NSObjectProtocol?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    /// When the user last switched *to* each running app, as observed by us.
    ///
    /// `NSRunningApplication` reports when an app was launched and nothing about
    /// when it was last used, and `kMDItemLastUsedDate` on an app bundle is
    /// updated by LaunchServices on launch rather than on activation — so
    /// Terminal, sitting right in front of the user with a cursor blinking in
    /// it, reported "1 hr ago". This is the missing observation, and it is only
    /// ever an *addition* to the evidence: it decides what a card says and
    /// whether an old flick still stands, and never where a card sits. Deck
    /// order stays the shared file lists', which is the whole point of them.
    @ObservationIgnored private var activationDates: [URL: Date] = [:]

    /// Freshness bookkeeping for `cachedDocumentsByApp`.
    ///
    /// Building that index reads and bookmark-resolves ~60 per-app `.sfl4`
    /// files, which measures at around 250 ms. `refresh()` runs on the main
    /// thread on every summon and every pin toggle, so that is a quarter of a
    /// second of frozen UI between the hotkey and the deck appearing — and the
    /// original ten-second cache lifetime was short enough that essentially
    /// every summon paid it.
    ///
    /// So it is not built on the way to showing the deck. `refresh()` uses
    /// whatever index it has, a stale or empty one included, and a fresh build
    /// runs on a background queue and folds itself in with a second refresh when
    /// it lands. A chevron that is a beat late is invisible; the hitch was not.
    /// The lifetime is a backstop rather than the mechanism: the directory these
    /// lists live in is watched, so a genuine change invalidates it immediately.
    @ObservationIgnored private var ownersCachedAt: Date = .distantPast
    @ObservationIgnored private var isLoadingOwners = false
    @ObservationIgnored private let ownersCacheLifetime: TimeInterval = 300

    /// bundle identifier (lowercased) → the documents that app's card expands
    /// into, in the app's own recency order.
    ///
    /// Filled on a background queue by `loadDocumentOwners()`, from two sources
    /// merged there: the per-app shared file lists, and
    /// Office's private bookmark stores for the three apps whose shared lists
    /// are empty. See `SharedFileListReader.DocumentIndex` and
    /// `OfficeRecentsReader`.
    ///
    /// Already pruned to files that exist and already capped — see
    /// `pruneToLiveDocuments`. That is what lets `hasRecentDocuments` be honest
    /// without touching the filesystem from a view body.
    @ObservationIgnored private var cachedDocumentsByApp: [String: [URL]] = [:]

    /// Every recent document from every app, newest first — the rail
    /// `Preferences.showAllFiles` puts on screen.
    ///
    /// Built on the same background pass as the index below, and for the same
    /// reason: it unions sixty per-app lists with the Apple menu's global one and
    /// then needs a `kMDItemLastUsedDate` for each survivor to order them, which
    /// is several hundred metadata lookups. Doing that on the way to showing the
    /// deck would put the whole cost between the hotkey and the first frame.
    ///
    /// Empty until that pass has run once, exactly like the chevrons: the first
    /// summon after launch shows the global list alone and the build folds the
    /// rest in with a second refresh. Only maintained while the preference is on.
    @ObservationIgnored private var cachedAllFilesOrder: [URL] = []

    /// What `showAllFiles` was on the last index build, so flipping it can force
    /// the rebuild that a merely-stale-in-five-minutes check would not.
    @ObservationIgnored private var indexedAllFiles = false

    /// document URL → the bundle identifier of the app whose list it came from.
    ///
    /// Discarded until the main deck could carry documents from more than one
    /// app: with every card badged Preview there was nothing to look up. It is
    /// the same read that fills `cachedDocumentsByApp` and costs one dictionary
    /// to keep, and it is better evidence than LaunchServices — it says which
    /// app *did* open a file rather than which one would.
    @ObservationIgnored private var cachedDocumentOwners: [URL: String] = [:]

    /// How many document cards the main deck would carry if the count in
    /// Settings were not capping it.
    ///
    /// Exists so the Settings stepper can stop where the deck does. Offering to
    /// show fifty documents on a machine whose recents list holds twelve sets a
    /// number nothing can reach and reads as though the deck were broken.
    private(set) var availableDocumentCount = 0

    /// Called after every recomputation, for the `--dump --watch` harness.
    @ObservationIgnored var onRefresh: (() -> Void)?

    // MARK: - Lifecycle

    func start() {
        spotlight.onChange = { [weak self] dates in
            guard let self else { return }
            self.spotlightDates = dates
            self.scheduleRefresh()
        }
        spotlight.start()

        // `RecentDocuments.sfl4` is absent from this list because the main deck
        // only reads it while `showAllFiles` is on, and watching a file that is
        // rewritten every time any app opens any document costs a rebuild per
        // save for the majority who are not reading it. It gets its own watcher,
        // armed and disarmed with the preference — see
        // `updateGlobalDocumentsWatcher`. Preview's own list, which the deck
        // reads either way, lives in the per-app directory watched below.
        for list: SharedFileListReader.List in [.recentApplications, .recentServers] {
            let watcher = FileWatcher(url: SharedFileListReader.url(for: list)) { [weak self] in
                // Hop to main before touching anything on this class.
                //
                // `FileWatcher` delivers on its own private serial queue while
                // `SpotlightSource` delivers on the main queue, and both land in
                // `scheduleRefresh()`, which read-modify-writes `refreshWorkItem`
                // — a strong reference. ThreadSanitizer reports the race on that
                // slot directly. Concurrent ARC assignment to a strong reference
                // can over-release, so the symptom is not a stale work item but a
                // crash in `swift_release` with nothing to connect it to the file
                // watcher. Every other entry point into this class is already on
                // the main thread, so this one hop makes the class main-isolated
                // in fact as well as in intent.
                DispatchQueue.main.async { self?.scheduleRefresh() }
            }
            watchers.append(watcher)
        }

        // The per-app document lists decide which app icon badges each document
        // card. Watching the directory they live in is what lets the ownership
        // map be cached for minutes instead of seconds: `sharedfilelistd`
        // renames a new list into place on every change, and a rename is a write
        // to the enclosing directory.
        let ownersDirectory = SharedFileListReader.appDocumentsDirectory
        watchers.append(FileWatcher(url: ownersDirectory) { [weak self] in
            DispatchQueue.main.async {
                self?.invalidateDocumentOwners()
                self?.scheduleRefresh()
            }
        })

        // Word, Excel and PowerPoint rewrite their bookmark store when they
        // open or close a document, and it lives nowhere near the shared file
        // lists — so the directory watcher above cannot see it, and without
        // these an app card's recents would be as old as the last shared-list
        // change. Only stores that exist are watched: a machine without Office
        // should not carry three retry timers for the life of the process.
        for store in OfficeRecentsReader.existingStoreURLs() {
            watchers.append(FileWatcher(url: store) { [weak self] in
                DispatchQueue.main.async {
                    self?.invalidateDocumentOwners()
                    self?.scheduleRefresh()
                }
            })
        }

        // The deck promises that every app currently open — everything showing a
        // running indicator in the Dock — has a card. That was true only at the
        // moment of a refresh: launch an app while the deck is on screen and the
        // rail did not notice until something else happened to trigger one.
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            workspaceObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in self?.scheduleRefresh()
                }
            )
        }

        // Switching to an app is the strongest evidence there is that it is in
        // use, and it is the only such evidence macOS does not record anywhere
        // we can read. Noted, never acted on immediately: a refresh on every
        // ⌘-Tab would rebuild the deck all day for a change nobody is looking at.
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                    app.bundleIdentifier != Bundle.main.bundleIdentifier,
                    let url = app.bundleURL
                else { return }
                self?.activationDates[url.standardizedFileURL] = Date()
            }
        )

        // Showing or hiding applications, documents or folders changes which
        // items exist, so it has to rebuild the list rather than just redraw it.
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .recentsContentPreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // Switching sources changes which file has to be watched, not just
            // what the next pass reads — without this, turning "all files" on
            // gave a deck that was correct when summoned and then never noticed
            // another document being opened.
            self?.updateGlobalDocumentsWatcher()
            // And the merged order only exists while the preference is on, so
            // turning it on has to rebuild rather than wait out the cache.
            if self?.indexedAllFiles != Preferences.shared.showAllFiles {
                self?.invalidateDocumentOwners()
            }
            self?.refresh()
        }

        updateGlobalDocumentsWatcher()
        refresh()
    }

    /// Arms a watcher on the Apple menu's global recent-documents list while the
    /// deck is actually reading it, and drops it again when it is not.
    private func updateGlobalDocumentsWatcher() {
        let wanted = prefs.showDocuments && prefs.showAllFiles

        if wanted, globalDocumentsWatcher == nil {
            globalDocumentsWatcher = FileWatcher(
                url: SharedFileListReader.url(for: .recentDocuments)
            ) { [weak self] in
                // Same hop as the watchers above, for the same reason.
                DispatchQueue.main.async { self?.scheduleRefresh() }
            }
        } else if !wanted, let watcher = globalDocumentsWatcher {
            watcher.stop()
            globalDocumentsWatcher = nil
        }
    }

    func stop() {
        spotlight.stop()
        watchers.forEach { $0.stop() }
        watchers.removeAll()
        globalDocumentsWatcher?.stop()
        globalDocumentsWatcher = nil
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
        preferenceObserver = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    /// Debounced: a single user action can trigger a shared-list rewrite and a
    /// Spotlight update within milliseconds of each other.
    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - The merge

    func refresh() {
        var result: [RecentItem] = []
        var rank = 0

        // Reset first: a group that is switched off contributes no verdict, so
        // the banner cannot keep asserting what it last found — including after
        // the user grants access.
        applicationsDenied = false
        documentsDenied = false
        serversDenied = false

        // Unconditional, and first: the per-app index feeds every application
        // card's chevron and sub-deck, so it has to be kept warm even when the
        // main deck is showing nothing that depends on it. This only ever kicks
        // a background build — it never blocks this pass, and the build folds
        // itself in with a second refresh when it lands.
        ensureDocumentIndex()

        if prefs.showApplications {
            result.append(contentsOf: loadApplications(startingAt: &rank))
        }
        if prefs.showDocuments {
            result.append(contentsOf: loadDocuments(startingAt: &rank))
        }
        if prefs.showServers {
            result.append(contentsOf: loadServers(startingAt: &rank))
        }

        needsFullDiskAccess = applicationsDenied || documentsDenied || serversDenied

        // Two groups can still name the same URL — a bundle dropped on Preview
        // lands in both lists — which would put it in the deck twice. `ForEach`
        // keys on that URL, and duplicate ids are undefined behaviour.
        var seenURLs: Set<URL> = []
        result = result.filter { seenURLs.insert($0.url).inserted }

        // Pinned items hold the front of the deck, in the order they were pinned.
        result.sort { a, b in
            switch (a.isPinned, b.isPinned) {
            case (true, true):
                return (userState.pinnedRank(a.url) ?? 0) < (userState.pinnedRank(b.url) ?? 0)
            case (true, false): return true
            case (false, true): return false
            case (false, false): return a.rank < b.rank
            }
        }

        items = result
        onRefresh?()
    }

    // MARK: - Applications

    private func loadApplications(startingAt rank: inout Int) -> [RecentItem] {
        var seen: Set<URL> = []
        var apps: [RecentItem] = []

        // macOS's own recent-applications list, in macOS's own order. This is
        // what the Apple menu shows, so it leads — and it is emphatically not
        // re-sorted afterwards.
        //
        // The previous version promoted every running application to the front,
        // ordered by launch date. That reads plausibly and is wrong: launch date
        // is when an app was started, not when it was last used, so an editor
        // opened at breakfast outranked the one switched to a minute ago, and the
        // deck's order stopped matching the Apple menu's entirely.
        switch SharedFileListReader.read(.recentApplications) {
        case .denied:
            applicationsDenied = true
        case .missing:
            break
        case .ok(let urls):
            for url in urls where seen.insert(url).inserted {
                apps.append(makeApplication(url: url, rank: &rank, origin: .sharedFileList))
            }
        }

        // Then everything currently running that the list has not caught up
        // with. Between the two passes this is the guarantee that every app open
        // in the Dock has a card: the shared list covers the ones macOS has
        // recorded, and this covers the rest — a freshly launched app takes a
        // moment to appear in the list, and while the list is unreadable this is
        // the only application source there is. `.regular` is precisely the
        // Dock's own test, so the two agree by construction. Appended, not
        // interleaved: these are the entries the Apple menu does not vouch for.
        let running = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }

        for app in running {
            guard let url = app.bundleURL, seen.insert(url).inserted else { continue }
            apps.append(makeApplication(url: url, rank: &rank, origin: .runningApplication))
        }

        // Launching an app is evidence that the user wants it, and switching to
        // one is stronger evidence still. Neither plays any part in ordering —
        // see the note above — they decide what a card *says* and whether an old
        // flick still stands.
        //
        // The flick part is the one that matters for the promise that every open
        // app has a card. A dated flick is superseded by later use, and without
        // an activation date the only later use we could see was the launch — so
        // an app forgotten yesterday and still running today stayed invisible
        // while the user was working in it, which is exactly what dating the
        // flick was meant to prevent.
        var usage: [URL: Date] = [:]
        for app in running {
            guard let url = app.bundleURL?.standardizedFileURL else { continue }
            let observed = [app.launchDate, activationDates[url]].compactMap { $0 }
            guard let newest = observed.max() else { continue }
            usage[url] = newest
        }

        return apps.compactMap { app in
            let usedAt = [app.lastUsed, usage[app.url.standardizedFileURL]]
                .compactMap { $0 }.max()
            guard !userState.isSuppressed(app.url, usedAt: usedAt), app.stillExists else {
                return nil
            }
            // The subtitle should report the newest thing we actually know, not
            // just the newest thing Spotlight knows.
            var app = app
            app.lastUsed = usedAt
            return app
        }
    }

    private func makeApplication(
        url: URL, rank: inout Int, origin: RecentItem.Origin
    ) -> RecentItem {
        var item = RecentItem(
            url: url, rank: rank, lastUsed: Self.lastUsedDate(for: url),
            owningApp: url, origin: origin
        )
        item.kind = .application
        item.isPinned = userState.isPinned(url)
        rank += 1
        return item
    }

    /// Reads `kMDItemLastUsedDate` directly for one file.
    ///
    /// `SpotlightSource` deliberately filters app bundles out of its live query
    /// (they would swamp the document results), so applications need their
    /// timestamp fetched individually. This is a cheap synchronous lookup and
    /// there are only ever a couple of dozen apps.
    private static func lastUsedDate(for url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: - Servers

    /// The third list the Apple menu's Recent Items shows. Small, usually empty,
    /// and cheap — but leaving it out meant the deck could not honestly claim to
    /// mirror that menu.
    private func loadServers(startingAt rank: inout Int) -> [RecentItem] {
        var servers: [RecentItem] = []

        switch SharedFileListReader.read(.recentServers) {
        case .denied:
            // The same TCC failure as the other two lists — and unlike documents,
            // there is no Spotlight equivalent to fall back on, so a denied
            // servers list simply means no server cards at all.
            serversDenied = true
        case .missing:
            break
        case .ok(let urls):
            for url in urls where !userState.isSuppressed(url) {
                var item = RecentItem(
                    url: url, rank: rank, lastUsed: nil,
                    owningApp: nil, origin: .sharedFileList
                )
                item.kind = .server
                item.isPinned = userState.isPinned(url)
                servers.append(item)
                rank += 1
            }
        }

        return servers
    }

    // MARK: - Documents

    /// The main deck's documents, capped at `Preferences.documentLimit`.
    ///
    /// Two possible sources, and the preference picks between them rather than
    /// blending them:
    ///
    ///   • **Preview's own list** (the default) —
    ///     `ApplicationRecentDocuments/com.apple.preview.sfl4`. This used to be
    ///     the Apple menu's global `RecentDocuments.sfl4` merged with a week of
    ///     Spotlight, which meant every file every app had touched landed in the
    ///     main rail — and each of those apps already carries its own recents one
    ///     swipe behind its card. The deck said the same thing twice, and the
    ///     louder half was the flat, unattributed one. So by default the main
    ///     deck answers a narrower question: what have you been *reading*.
    ///     Preview is the app with no project and no workspace to expand into —
    ///     a PDF opened there belongs nowhere else — so its list is the one that
    ///     earns a place beside the app cards.
    ///
    ///   • **Every app's files** (`Preferences.showAllFiles`) — every per-app
    ///     list unioned with the Apple menu's global one and ordered by
    ///     timestamp. See `mergedDocumentOrder` for why the global list is not
    ///     enough on its own, and why a timestamp order is the only one available
    ///     across apps. These cards are marked `.spotlight` rather than
    ///     `.sharedFileList` because that is exactly what they are: real
    ///     timestamps, and an order no shared file list vouches for.
    ///
    /// In the default mode the list is read straight from its file rather than
    /// filtered out of the cached ownership index, for two reasons. It is
    /// authoritative about order, where the index's `owners` map only records
    /// which app happened to claim a URL first. And it is synchronous, so the
    /// first summon after launch shows documents instead of waiting on the
    /// background build — which the all-files rail, by its nature, cannot.
    private func loadDocuments(startingAt rank: inout Int) -> [RecentItem] {
        // Step 1 — the list, in its own order. A `.denied` here is the same TCC
        // signature as the other lists: the file exists and will not open, which
        // is what the Full Disk Access banner reports.
        let showingEveryApp = prefs.showAllFiles
        var order: [URL] = []

        if showingEveryApp {
            // Pre-merged and pre-sorted by the background pass. The global list
            // is still read here, and only for its verdict: it is the one input
            // to that merge that can come back `.denied`, and the Full Disk
            // Access banner has to say so.
            if case .denied = SharedFileListReader.read(.recentDocuments) {
                documentsDenied = true
            }
            order = cachedAllFilesOrder
        } else {
            switch SharedFileListReader.readAppDocuments(bundleID: Self.previewBundleID) {
            case .denied:
                documentsDenied = true
            case .missing:
                break
            case .ok(let urls):
                order = urls
            }
        }

        // In the default mode every card came from Preview, so the badge is
        // Preview and is resolved once rather than per document. Showing every
        // app's files makes the question real, and it is answered per card in
        // `owningApplication(for:)` — but only for the cards that survive the
        // cap, since that lookup is the one expensive thing in this loop.
        let previewApp = showingEveryApp
            ? nil
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.previewBundleID)

        // Step 2 — filter, count and cap in one pass.
        //
        // This used to stop dead at the cap, so a long list cost nothing once
        // enough survivors were found. It now runs to the end, because
        // `availableDocumentCount` is what stops the Settings stepper offering a
        // number the deck could never reach — and that number cannot be known
        // without asking of every entry the same questions the cap would have.
        // Past the cap those questions are answered as cheaply as they can be:
        // two stats, no card, and no timestamp unless a flick is on file for the
        // URL and might have expired.
        var documents: [RecentItem] = []
        var seen: Set<URL> = []
        var available = 0
        let limit = prefs.documentLimit
        documents.reserveCapacity(limit)

        for url in order {
            guard seen.insert(url).inserted else { continue }
            let wantsCard = documents.count < limit

            // Spotlight's window is a week, and a document read a fortnight ago
            // is still perfectly real — so fall back to reading the attribute
            // directly. At most `limit` of those per refresh, plus one per
            // entry the user has actually flicked away.
            let usedAt: Date? = wantsCard || userState.isSuppressed(url)
                ? spotlightDates[url] ?? Self.lastUsedDate(for: url)
                : nil

            guard !userState.isSuppressed(url, usedAt: usedAt) else { continue }
            // Recents lists go stale constantly — files get moved, renamed and
            // deleted out from under them. A deck of dead cards is worse than a
            // short one.
            var item = RecentItem(
                url: url, rank: documents.count, lastUsed: usedAt,
                // The flat rail is ordered by timestamp, which no shared file
                // list vouches for. Saying so here is what keeps `--parity`
                // honest and the "Apple menu order" claim true.
                owningApp: nil, origin: showingEveryApp ? .spotlight : .sharedFileList
            )
            guard item.stillExists else { continue }
            // Preview does not open folders, so in the default mode this is very
            // nearly dead code — but the preference means "no folders in the
            // deck", and a rule that quietly stops applying in one place is worse
            // than a redundant check. Reading every app's files is where it earns
            // its keep: editors put their project directories in that list.
            guard prefs.includeFolders || !item.isDirectory else { continue }

            available += 1
            guard wantsCard else { continue }

            item.kind = .document
            item.owningApp = previewApp ?? owningApplication(for: url)
            item.isPinned = userState.isPinned(url)
            documents.append(item)
        }

        availableDocumentCount = available

        // Step 3 — renumber into the deck-wide rank space.
        for index in documents.indices {
            documents[index].rank = rank
            rank += 1
        }
        return documents
    }

    /// Which app a document card is badged with, while the deck is carrying more
    /// than one app's files.
    ///
    /// The per-app index is asked first because it is the better answer: it
    /// records which app's list the URL actually appeared in, where
    /// LaunchServices reports which app *would* open the file today. It is built
    /// in the background and can be empty on the first summon after launch, and
    /// Office's documents reach it a beat later still, so LaunchServices is the
    /// fallback rather than nothing — an unbadged card is worse than one badged
    /// with the default app.
    private func owningApplication(for url: URL) -> URL? {
        if let bundleID = cachedDocumentOwners[url],
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return app
        }
        return NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    /// The one app whose recents the main deck carries by default. See
    /// `loadDocuments`.
    private static let previewBundleID = "com.apple.Preview"

    /// Kicks a rebuild of the per-app index if it has gone stale, and returns
    /// immediately either way. See `cachedDocumentsByApp` for why this must not
    /// block.
    ///
    /// Called from `refresh()` rather than from whatever consumes the index,
    /// which is the only place it can now live: the main deck stopped reading
    /// the index when its documents became Preview's list, and the index's only
    /// remaining consumers — `recentDocuments(forApp:)` and
    /// `hasRecentDocuments` — are called from view bodies, which must never
    /// start file I/O. Left attached to the old caller, nothing triggered the
    /// build at all and every app card's sub-deck was silently empty.
    private func ensureDocumentIndex() {
        if Date().timeIntervalSince(ownersCachedAt) >= ownersCacheLifetime {
            loadDocumentOwners()
        }
    }

    private func invalidateDocumentOwners() {
        ownersCachedAt = .distantPast
    }

    /// Rebuilds the ownership map off the main thread, then refreshes again if
    /// the answer actually changed.
    private func loadDocumentOwners() {
        guard !isLoadingOwners else { return }
        isLoadingOwners = true
        // Stamped now rather than on completion: otherwise every refresh during
        // the ~250 ms read would see a stale timestamp and queue another one.
        ownersCachedAt = Date()

        // Read here rather than inside the block: `Preferences` is `@Observable`
        // and main-isolated in practice, and this is the one place in the class
        // that leaves the main thread.
        let wantsAllFiles = prefs.showAllFiles

        DispatchQueue.global(qos: .userInitiated).async {
            // Two sources, merged in this order on purpose. The shared file
            // lists are what macOS itself says, so they are laid down first and
            // Office only fills the gaps they leave — which, for Word, Excel and
            // PowerPoint, is everything: their `.sfl4` lists exist but hold zero
            // items, so before this merge those three app cards had nothing to
            // expand into. Both reads are file I/O and both belong off the main
            // thread, which is why they share this one hop.
            var index = SharedFileListReader.documentIndex()
            index.merge(OfficeRecentsReader.documentIndex())
            Self.pruneToLiveDocuments(&index)

            // The flat rail, ordered while we are already off the main thread.
            let allFiles = wantsAllFiles ? Self.mergedDocumentOrder(index) : []

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLoadingOwners = false
                self.ownersCachedAt = Date()
                self.indexedAllFiles = wantsAllFiles

                let documentsChanged = index.documentsByApp != self.cachedDocumentsByApp
                    || index.owners != self.cachedDocumentOwners
                    || allFiles != self.cachedAllFilesOrder
                self.cachedDocumentsByApp = index.documentsByApp
                self.cachedDocumentOwners = index.owners
                self.cachedAllFilesOrder = allFiles

                // The chevron that says a card can be expanded is driven by
                // `documentsByApp`, and the badge on a document card by `owners`.
                // Both are `@ObservationIgnored`, so a change here reaches the UI
                // only by way of a refresh.
                guard documentsChanged else { return }
                // Only chevrons and sub-decks depend on this, so the second pass
                // is cheap — and it cannot recurse, because the cache it just
                // filled is now fresh.
                self.refresh()
            }
        }
    }

    /// Reduces each app's list to the documents its card can actually show.
    ///
    /// These lists are long and mostly dead. Word's private store holds 119
    /// entries of which 36 still exist; PowerPoint's holds 20 of which *none*
    /// do — every file the user opened in it has since been moved or deleted.
    /// Left unpruned, that last case put a chevron on the PowerPoint card
    /// promising a sub-deck, and the swipe then did nothing, because
    /// `recentDocuments(forApp:)` filtered all twenty away at the last moment.
    ///
    /// Doing it here rather than at the point of use is what makes
    /// `hasRecentDocuments` both correct and free: it runs once per index build,
    /// on the background queue that was already reading sixty files, instead of
    /// stat-ing the filesystem from inside a SwiftUI body. An app with nothing
    /// live left is dropped entirely, so "has a key" and "has documents" become
    /// the same question.
    ///
    /// The cap is applied in the same pass because it bounds the work: once six
    /// survivors are found the remaining ninety entries are never touched.
    static func pruneToLiveDocuments(_ index: inout SharedFileListReader.DocumentIndex) {
        for (bundleID, urls) in index.documentsByApp {
            var live: [URL] = []
            live.reserveCapacity(maximumDocumentsPerApp)

            for url in urls {
                // A non-file URL cannot be stat-ed and is not this list's
                // business anyway; keeping it is the conservative choice.
                if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
                    continue
                }
                live.append(url)
                if live.count == maximumDocumentsPerApp { break }
            }

            if live.isEmpty {
                index.documentsByApp.removeValue(forKey: bundleID)
            } else {
                index.documentsByApp[bundleID] = live
            }
        }
    }

    /// Every app's recents as one rail, newest first.
    ///
    /// Two inputs. The per-app lists are the substance: on a real machine the
    /// Apple menu's global `RecentDocuments.sfl4` turns out to hold a handful of
    /// entries from a couple of apps and nothing at all from Preview, so reading
    /// it alone gave a "show all files" rail *shorter* than the Preview-only one
    /// it replaced. The global list is unioned in anyway, because it is cheap and
    /// it occasionally knows about something no per-app list does.
    ///
    /// The order is the honest part. Within one app's list there is a real
    /// recency order and the deck preserves it everywhere else; *across* sixty of
    /// them there is none, because no list ranks another app's entries — so the
    /// only order available is the one the timestamps give. That is a genuine
    /// departure from the rest of the app, which is why these cards are marked
    /// `.spotlight` rather than `.sharedFileList` in `loadDocuments`: the deck
    /// says out loud that this rail is dated evidence rather than macOS's own
    /// sequence, and `--parity` skips it instead of failing it.
    ///
    /// Entries with no timestamp at all sort last, in a stable order, rather than
    /// being dropped: a file macOS recorded and Spotlight has never indexed is
    /// still a file the user opened.
    private static func mergedDocumentOrder(
        _ index: SharedFileListReader.DocumentIndex
    ) -> [URL] {
        var seen: Set<URL> = []
        var candidates: [URL] = []

        for urls in index.documentsByApp.values {
            for url in urls where seen.insert(url).inserted { candidates.append(url) }
        }
        for url in SharedFileListReader.urls(for: .recentDocuments)
        where seen.insert(url).inserted {
            candidates.append(url)
        }

        // One metadata lookup per candidate, done once here rather than once per
        // comparison — `sorted(by:)` would otherwise ask for the same date a
        // logarithmic number of times each.
        return orderedByRecency(candidates.map { (url: $0, usedAt: lastUsedDate(for: $0)) })
    }

    /// Newest first; entries with no timestamp last; ties and undated entries in
    /// the order they were given.
    ///
    /// Separated from the metadata lookup above so the ordering rule can be
    /// tested on its own. It is the one place in the app that invents an order
    /// rather than reproducing macOS's, so it is also the one most worth
    /// pinning down: `sorted(by:)` is not a stable sort in Swift, and the
    /// stability here is carried by the explicit index rather than assumed.
    static func orderedByRecency(_ dated: [(url: URL, usedAt: Date?)]) -> [URL] {
        dated
            .enumerated()
            .sorted { a, b in
                switch (a.element.usedAt, b.element.usedAt) {
                case let (x?, y?): return x == y ? a.offset < b.offset : x > y
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return a.offset < b.offset
                }
            }
            .map(\.element.url)
    }

    /// How many documents an application card expands into.
    ///
    /// These lists run to three figures, and a sub-deck you have to scrub
    /// through is not a shortcut. Six is what fits on screen at once, and it is
    /// the six most recent: every source hands its entries over newest-first, so
    /// the cap takes the top of the list rather than a slice of an arbitrary one.
    private static let maximumDocumentsPerApp = 6

    // MARK: - Per-application recents

    /// What one application has been opening, as cards.
    ///
    /// This is the application card's own list rather than a slice of the deck:
    /// it comes from `ApplicationRecentDocuments/<bundleID>.sfl4`, in that
    /// list's own order, which is the order the app itself would show.
    ///
    /// Folders are deliberately *not* filtered here, and that is the whole point
    /// rather than an oversight. The `includeFolders` preference exists because
    /// editors register project directories as recent documents and flood the
    /// main deck with folders duplicating the app cards above them. Inside one
    /// app's own list that reasoning inverts — VS Code's recents are almost
    /// entirely folders, and a sub-deck that hid them would be empty. The main
    /// deck's rule is untouched: this simply never goes through `loadDocuments`.
    ///
    /// Both the staleness filter and the six-card cap have already been applied
    /// to the cached index — see `pruneToLiveDocuments`. The `stillExists` check
    /// below is not a duplicate of that but the last word on it: the index can
    /// be up to five minutes old, and a card that opens nothing is worse than a
    /// shorter list.
    func recentDocuments(forApp item: RecentItem) -> [RecentItem] {
        guard item.kind == .application, let bundleID = item.bundleID else { return [] }
        guard let urls = cachedDocumentsByApp[bundleID.lowercased()] else { return [] }

        var seen: Set<URL> = []
        var documents: [RecentItem] = []
        var rank = 0

        for url in urls where seen.insert(url).inserted {
            var document = RecentItem(
                url: url, rank: rank, lastUsed: nil,
                owningApp: item.url, origin: .sharedFileList
            )
            document.kind = .document
            document.isPinned = userState.isPinned(url)
            // Same staleness rule the deck applies everywhere else: a card that
            // opens nothing is worse than a shorter list.
            guard document.stillExists else { continue }
            documents.append(document)
            rank += 1
        }

        return documents
    }

    /// Whether an application card has anything to expand into.
    ///
    /// Answered from the cached index with no filesystem access, which is what
    /// makes it cheap enough for a view body — and, since that index now holds
    /// only documents that exist, it is also the same answer
    /// `recentDocuments(forApp:)` will give. A chevron that promises a sub-deck
    /// and then delivers an empty one is worse than no chevron.
    func hasRecentDocuments(_ item: RecentItem) -> Bool {
        guard item.kind == .application, let bundleID = item.bundleID else { return false }
        return !(cachedDocumentsByApp[bundleID.lowercased()] ?? []).isEmpty
    }

    // MARK: - Actions

    func open(_ item: RecentItem) {
        if item.kind == .application {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: item.url, configuration: config)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    func openWith(_ item: RecentItem, application: URL) {
        NSWorkspace.shared.open(
            [item.url], withApplicationAt: application,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func revealInFinder(_ item: RecentItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyPath(_ item: RecentItem) {
        // `.path` drops the scheme and the host, which is right for a file URL
        // and useless for anything else: a server card's `smb://nas.local/Media`
        // would go on the pasteboard as `/Media`. `RecentItem.displayName`
        // already special-cases `.server` this way.
        let string = item.url.isFileURL ? item.url.path : item.url.absoluteString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    func togglePin(_ item: RecentItem) {
        userState.togglePin(item.url)
        refresh()
    }

    func suppress(_ item: RecentItem) {
        userState.suppress(item.url)
        refresh()
    }

    @discardableResult
    func undoSuppress() -> URL? {
        let restored = userState.undoSuppress()
        refresh()
        return restored
    }

    var canUndo: Bool { userState.lastSuppressed != nil }
}
