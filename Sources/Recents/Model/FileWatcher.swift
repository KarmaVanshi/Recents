import Foundation

/// Watches a single file for changes, surviving atomic replacement.
///
/// This exists because the obvious implementation is subtly broken.
/// `sharedfilelistd` rewrites the `.sfl4` files by writing a temp file and
/// renaming it into place. That means the inode our descriptor points at is
/// unlinked, and a `DispatchSource` armed on it fires `.delete` exactly once and
/// then goes permanently silent — the watcher appears to work in testing and
/// then stops updating forever.
///
/// So on `.delete` / `.rename` we tear down and re-arm against the new inode.
final class FileWatcher {

    private let url: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.recents.filewatcher")

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var isStopped = false

    /// Backoff for a file that is not there. Some of the lists this watches —
    /// `RecentServers.sfl4` most of all — simply do not exist on a machine that
    /// has never used the feature, and retrying such a file once a second forever
    /// is a wakeup per second for something that will never appear.
    private var retryDelay: TimeInterval = 1
    private let maximumRetryDelay: TimeInterval = 30

    /// Marks blocks running on `queue`, so `stop()` can tell whether it is
    /// already there. See the deadlock note on `stop()`.
    private static let queueKey = DispatchSpecificKey<UInt8>()

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        queue.setSpecific(key: Self.queueKey, value: 1)
        queue.async { [weak self] in self?.arm() }
    }

    /// Deliberately not `stop()`.
    ///
    /// The last reference to a watcher is routinely released by one of its own
    /// blocks finishing on `queue` — every one of them promotes a weak `self` to
    /// strong for its duration. Deallocation therefore happens *on* the queue,
    /// and `stop()`'s `queue.sync` from inside the queue it is targeting is an
    /// immediate deadlock, which libdispatch traps rather than hangs on. By the
    /// time deinit runs no other reference exists, so touching the state directly
    /// is safe without the barrier.
    deinit {
        isStopped = true
        if let source {
            // The cancel handler owns the descriptor and closes it.
            source.cancel()
        } else if descriptor >= 0 {
            close(descriptor)
        }
        source = nil
        descriptor = -1
    }

    func stop() {
        // Same hazard as deinit, one step removed: a caller can reach `stop()`
        // from a callback already running on this queue.
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            isStopped = true
            disarm()
            return
        }
        queue.sync {
            isStopped = true
            disarm()
        }
    }

    private func arm() {
        guard !isStopped else { return }

        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The file may not exist yet, or may be mid-replacement. Retry
            // rather than giving up — this is a normal transient state — but back
            // off, so a list that never appears costs almost nothing.
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, maximumRetryDelay)
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.arm() }
            return
        }
        retryDelay = 1

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data

            self.onChange()

            if flags.contains(.delete) || flags.contains(.rename) {
                // The inode we were watching is gone. Re-arm on the replacement.
                self.disarm()
                self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.arm() }
            }
        }

        // Captures the descriptor by value rather than `self`. A cancel handler
        // that promotes a weak `self` can be the last thing holding the watcher
        // alive, and then deallocates it from inside its own queue — which is how
        // the deadlock described on `deinit` used to be reached.
        let fd = descriptor
        source.setCancelHandler { close(fd) }

        self.source = source
        source.resume()
    }

    /// Cancelling closes the descriptor through the cancel handler, so the
    /// bookkeeping is cleared here rather than in the handler.
    private func disarm() {
        source?.cancel()
        source = nil
        descriptor = -1
    }
}
