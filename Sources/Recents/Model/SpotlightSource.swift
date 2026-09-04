import Foundation

/// Live Spotlight feed of recently-used documents.
///
/// This is the breadth source. The shared file lists hold ~10 documents; this
/// query surfaces ~100+ per week, and crucially it catches apps like Word and
/// Excel that write nothing to the shared lists at all.
///
/// It also supplies the real `kMDItemLastUsedDate` timestamps that the shared
/// lists lack entirely.
final class SpotlightSource {

    /// How far back to look. A week keeps the deck relevant without dragging in
    /// months of noise.
    private let window: TimeInterval = 60 * 60 * 24 * 7

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []

    /// Called on the main queue whenever results change.
    var onChange: (([URL: Date]) -> Void)?

    init() {
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.valueListAttributes = [
            NSMetadataItemPathKey,
            NSMetadataItemLastUsedDateKey,
            NSMetadataItemContentTypeTreeKey,
        ]
        query.sortDescriptors = [
            NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)
        ]
        // Coalesce the firehose. Spotlight will happily notify on every single
        // metadata write otherwise.
        query.notificationBatchingInterval = 0.5
    }

    func start() {
        let since = Date().addingTimeInterval(-window)

        // Folders and app bundles are excluded here rather than after the fact:
        // the raw query returns a lot of both, and filtering in the predicate
        // keeps the result set small enough to stay cheap.
        query.predicate = NSPredicate(
            format: """
                %K >= %@ \
                AND NOT (%K == 'public.folder') \
                AND NOT (%K == 'com.apple.application-bundle') \
                AND NOT (%K == 'public.executable')
                """,
            NSMetadataItemLastUsedDateKey, since as NSDate,
            NSMetadataItemContentTypeTreeKey,
            NSMetadataItemContentTypeTreeKey,
            NSMetadataItemContentTypeTreeKey
        )

        for name: NSNotification.Name in [
            .NSMetadataQueryDidFinishGathering,
            .NSMetadataQueryDidUpdate,
        ] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] _ in
                self?.publish()
            }
            observers.append(token)
        }

        query.start()
    }

    func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit { stop() }

    private func publish() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var results: [URL: Date] = [:]
        results.reserveCapacity(query.resultCount)

        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }

            let date = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
            let url = URL(fileURLWithPath: path)

            // Spotlight indexes plenty of things the user never meaningfully
            // "opened" — caches, app-internal support files, mail attachments
            // staged in containers. They make the deck feel random, so drop them.
            guard !Self.isNoise(url) else { continue }

            results[url] = date ?? .distantPast
        }

        onChange?(results)
    }

    /// System bundle types that Spotlight reports as recently used whenever the
    /// OS touches them. They are not documents in any sense the user recognises
    /// — observed leaking in as "WritingToolsAppIntentsExtension.appex" and
    /// "Extensions.prefPane", attributed to Quick Look Simulator.
    private static let systemBundleExtensions: Set<String> = [
        "appex", "prefpane", "qlgenerator", "bundle", "framework", "plugin",
        "kext", "component", "mdimporter", "saver", "service", "xpc",
        "systemextension", "driver", "app", "dext", "audioplugin",
    ]

    /// Paths that are technically "recently used" but are never what the user
    /// means by a recent document.
    private static func isNoise(_ url: URL) -> Bool {
        let path = url.path

        let noisyFragments = [
            "/Library/Caches/",
            "/Library/Containers/",
            "/Library/Group Containers/",
            "/Library/Application Support/",
            "/System/",
            "/.Trash/",
            "/node_modules/",
            "/.git/",
            "/DerivedData/",
            "/.build/",
        ]
        if noisyFragments.contains(where: path.contains) { return true }

        if systemBundleExtensions.contains(url.pathExtension.lowercased()) { return true }

        // Dotfiles and package internals.
        if url.lastPathComponent.hasPrefix(".") { return true }

        return false
    }
}
