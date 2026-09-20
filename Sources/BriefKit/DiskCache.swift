import CryptoKit
import Foundation

/// Disk-backed storage for the last good payload of each feed URL.
///
/// Lives in **Application Support, not Caches**. The system may evict the
/// Caches directory under storage pressure at any time, and evicting the only
/// copy of the briefing is precisely the failure this whole design exists to
/// prevent. The data is a few tens of kilobytes and its entire job is to
/// survive.
public actor DiskCache {
    public static let shared = DiskCache()

    private let directory: URL

    public init(directoryName: String = "FeedCache") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    /// SHA-256 of the URL, so the filename is bounded and safe regardless of
    /// query strings or path length.
    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    /// The stored bytes and when they were written. The file's modification
    /// date *is* the fetch time — we write immediately on a successful fetch —
    /// which avoids a sidecar file that could fall out of sync with the body.
    public func read(for url: URL) -> (data: Data, fetchedAt: Date)? {
        let file = fileURL(for: url)
        guard let data = try? Data(contentsOf: file),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return (data, modified)
    }

    /// Returns the fetch timestamp on success, nil if the write failed.
    ///
    /// Written atomically: a half-written cache file left behind by a crash or
    /// a suspended app would be worse than having no cache at all, because it
    /// would fail to decode and look like corruption rather than absence.
    @discardableResult
    public func write(_ data: Data, for url: URL) -> Date? {
        do {
            try data.write(to: fileURL(for: url), options: .atomic)
            return Date()
        } catch {
            return nil
        }
    }

    public func clear(for url: URL) {
        try? FileManager.default.removeItem(at: fileURL(for: url))
    }
}
