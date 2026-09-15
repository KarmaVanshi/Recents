import Foundation

/// Recently-read `kMDItemLastUsedDate` values, held long enough that a burst of
/// refreshes reads each file once rather than once per refresh.
///
/// See `RecentsStore.lastUsedDate` for what is being held and why holding it is
/// safe. This is the mechanism only.
///
/// Locked rather than confined to the main actor, because both of the store's
/// threads ask for these: `refresh()` on the main thread, and
/// `mergedDocumentOrder` on the background queue the per-application document
/// index is built on.
final class LastUsedDates: @unchecked Sendable {

    static let shared = LastUsedDates()

    /// How long a value is trusted for.
    ///
    /// A minute is far below the granularity of the abbreviated relative date
    /// these end up drawn as — "5 hrs ago" — so nothing the user can read is
    /// ever stale by it, while a storm of watcher-driven refreshes still costs
    /// one read between them rather than one each.
    private let lifetime: TimeInterval

    /// Above this many entries, expired ones are swept before another is added.
    /// Far beyond any real deck; it exists so that a session spent opening
    /// thousands of files cannot grow this without end.
    private let capacity: Int

    private let lock = NSLock()
    private var entries: [URL: (date: Date?, readAt: Date)] = [:]

    init(lifetime: TimeInterval = 60, capacity: Int = 4096) {
        self.lifetime = lifetime
        self.capacity = capacity
    }

    /// The file's timestamp, reading it through `read` only when there is no
    /// fresh answer already held.
    ///
    /// A missing timestamp is cached as readily as a present one: a file the
    /// metadata server has nothing to say about is exactly the file that would
    /// otherwise be asked about on every single refresh.
    func date(for url: URL, read: (URL) -> Date?) -> Date? {
        let now = Date()

        lock.lock()
        let hit = entries[url]
        lock.unlock()

        if let hit, now.timeIntervalSince(hit.readAt) < lifetime { return hit.date }

        // Deliberately outside the lock. The read is an interprocess round trip,
        // and holding the lock across it would let one thread's slow lookup
        // block the other's cache hits. Two threads racing on the same file
        // simply both read it, which costs a duplicate lookup and nothing else.
        let date = read(url)

        lock.lock()
        // Swept here rather than on a timer: it only ever needs doing while
        // entries are being added, and this is the only place that adds one.
        if entries.count >= capacity {
            entries = entries.filter { now.timeIntervalSince($0.value.readAt) < lifetime }
        }
        entries[url] = (date, now)
        lock.unlock()

        return date
    }

    /// How many values are currently held. For the test that the sweep bounds
    /// this rather than letting it grow.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
