import AppKit
import CryptoKit
import QuickLookThumbnailing

/// Produces and caches the live document previews that fill each card.
///
/// Three tiers, because the overlay must paint instantly and QuickLook is fast
/// but not free (~50-200ms per document):
///   1. memory LRU  — a second summon in the same session is immediate
///   2. disk cache  — a second summon after relaunch is immediate
///   3. QuickLook   — the real render, done off the main thread
///
/// The cache key includes modification date and size, so editing a document
/// invalidates its thumbnail naturally without any explicit purge. It also
/// includes the requested point size *and* the display scale, because those are
/// two different requests: 300×380 at 1× and at 2× are different images, and
/// serving the first to a Retina card is exactly how a thumbnail ends up soft.
///
/// Everything here works in two coordinate spaces and is careful about which:
/// QuickLook is asked in points and answers in pixels, and the resulting
/// `NSImage` is given a point size of `pixels / scale` so that AppKit, SwiftUI
/// and the no-upscale rule in `ThumbnailImage` all agree on its true resolution.
actor ThumbnailCache {

    static let shared = ThumbnailCache()

    private var memory: [String: NSImage] = [:]
    private var lru: [String] = []
    private let memoryLimit = 120

    /// Coalesces concurrent requests for the same file — while scrubbing, the
    /// same card can be asked for repeatedly before the first render lands.
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    private let diskDirectory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("Recents/thumbnails", isDirectory: true)
        // 0700, and set on an existing directory as well as a new one so a cache
        // written by an earlier build is tightened rather than left as it was.
        //
        // A rendered thumbnail is a picture of the first page of a document the
        // user opened — a contract, a payslip, a letter — which is the same class
        // of thing `AppWindowCapture` locks down, and `~/Library/Caches` is not
        // somewhere TCC protects. The default mode on a created directory is 0755
        // and on an atomic write 0644, so every one of these was readable by
        // anything else running as any user on the machine.
        try? FileManager.default.createDirectory(
            at: diskDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: diskDirectory.path
        )

        Task.detached(priority: .utility) { [diskDirectory] in
            Self.pruneDisk(at: diskDirectory)
        }
    }

    /// Keeps a written thumbnail readable only by this user. The directory above
    /// it is 0700 now, but a cache protected only by its parent is one `chmod`
    /// away from being readable again.
    private static func restrictPermissions(of url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    /// The disk key includes the file's modification date and size, which is what
    /// makes editing a document invalidate its thumbnail for free — and also what
    /// strands the old one on disk forever. A document edited daily leaves a
    /// year's worth of orphans behind it, so sweep anything untouched for a month.
    private static func pruneDisk(at directory: URL) {
        let keys: [URLResourceKey] = [.contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }

        let cutoff = Date().addingTimeInterval(-60 * 60 * 24 * 30)
        for file in files {
            // Anything an earlier build wrote is still 0644. The sweep is the one
            // pass that already visits every file, so it is where they are
            // tightened.
            restrictPermissions(of: file)

            let values = try? file.resourceValues(forKeys: Set(keys))
            let touched = values?.contentAccessDate
                ?? values?.contentModificationDate
                ?? .distantPast
            if touched < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: - Public

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let key = Self.cacheKey(for: url, size: size, scale: scale)

        if let hit = memory[key] {
            touch(key)
            return hit
        }

        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> { [diskDirectory] in
            // Disk tier.
            let diskURL = diskDirectory.appendingPathComponent(key + ".png")
            if let image = Self.loadFromDisk(diskURL, scale: scale) {
                return image
            }

            // Render tier.
            guard let image = await Self.render(url: url, size: size, scale: scale) else {
                return nil
            }

            if let png = image.pngData() {
                try? png.write(to: diskURL, options: .atomic)
                Self.restrictPermissions(of: diskURL)
            }
            return image
        }

        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        if let result {
            store(result, for: key)
        }
        return result
    }

    /// Warm the cache for cards about to scroll into view.
    func prefetch(_ urls: [URL], size: CGSize, scale: CGFloat) {
        for url in urls {
            let key = Self.cacheKey(for: url, size: size, scale: scale)
            guard memory[key] == nil, inFlight[key] == nil else { continue }
            Task { _ = await thumbnail(for: url, size: size, scale: scale) }
        }
    }

    // MARK: - Rendering

    private static func render(url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale,
            // .all lets QuickLook fall back gracefully: a real page render when
            // it can produce one, an enriched icon when it cannot. Restricting
            // to .thumbnail alone leaves many file types with nothing at all.
            representationTypes: .all
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                guard let rep else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.image(from: rep.cgImage, scale: scale))
            }
        }
    }

    /// Wraps a rendered bitmap with honest resolution metadata.
    ///
    /// The whole image is kept — no crop to `contentRect`, which would risk
    /// slicing a page down to a corner, and which is the opposite of preserving
    /// the complete document. Sizing in points rather than pixels is what lets
    /// the view layer tell a full-resolution page render apart from a 128px icon
    /// QuickLook substituted, and refuse to stretch the second one.
    private static func image(from cgImage: CGImage, scale: CGFloat) -> NSImage {
        let scale = max(scale, 1)
        return NSImage(
            cgImage: cgImage,
            size: NSSize(
                width: CGFloat(cgImage.width) / scale,
                height: CGFloat(cgImage.height) / scale
            )
        )
    }

    /// Reads a cached PNG back at the scale it was rendered for.
    ///
    /// `NSImage(data:)` alone would hand back an image whose point size equals
    /// its pixel count — a 2× thumbnail claiming to be twice its real size, which
    /// then looks half as sharp as the freshly-rendered one it is standing in
    /// for. The scale is known here because it is part of the cache key.
    private static func loadFromDisk(_ url: URL, scale: CGFloat) -> NSImage? {
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data)
        else { return nil }

        let scale = max(scale, 1)
        let image = NSImage(size: NSSize(
            width: CGFloat(rep.pixelsWide) / scale,
            height: CGFloat(rep.pixelsHigh) / scale
        ))
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Memory tier

    private func store(_ image: NSImage, for key: String) {
        memory[key] = image
        touch(key)
        while lru.count > memoryLimit {
            let evicted = lru.removeFirst()
            memory.removeValue(forKey: evicted)
        }
    }

    private func touch(_ key: String) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    // MARK: - Keys

    /// File identity (path, modification date, size) crossed with the exact
    /// request (point size and display scale). Both halves are load-bearing: the
    /// first invalidates on edit, the second keeps a 1× render from being served
    /// to a Retina card.
    private static func cacheKey(for url: URL, size: CGSize, scale: CGFloat) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let bytes = values?.fileSize ?? 0
        let seed = "\(url.path)|\(modified)|\(bytes)"
            + "|\(Int(size.width))x\(Int(size.height))@\(scale)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension NSImage {
    /// PNG at the image's true pixel resolution.
    ///
    /// `NSBitmapImageRep(data: tiffRepresentation)` was quietly lossy for
    /// anything above 1×: the TIFF round-trip collapses to the point size, so a
    /// Retina render was written to disk at half its resolution and came back
    /// soft. Encoding the largest existing bitmap representation directly keeps
    /// every pixel that was rendered.
    func pngData() -> Data? {
        let bitmaps = representations.compactMap { $0 as? NSBitmapImageRep }
        if let best = bitmaps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            return best.representation(using: .png, properties: [:])
        }

        // No bitmap rep (a vector or a CGImage-backed image): draw it out at full
        // pixel resolution rather than accepting AppKit's point-sized default.
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
