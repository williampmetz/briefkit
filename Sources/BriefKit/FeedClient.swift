import Foundation

private struct SchemaEnvelope: Decodable { let schema: Int }

/// Fetches and caches a static JSON feed.
///
/// The shape every app in this family shares: the server writes a JSON
/// artifact, nginx serves it, the client reads it. There is no API, no auth
/// and no write path — which is why this is small.
///
/// The contract that matters: **a failed refresh never damages the cache.**
/// Every failure path below returns before the write, so the last good copy
/// survives. Losing yesterday's briefing because today's fetch half-failed is
/// the worst outcome available.
public actor FeedClient {
    private let session: URLSession
    private let cache: DiskCache

    public init(cache: DiskCache = .shared, timeout: TimeInterval = 10) {
        let config = URLSessionConfiguration.default
        // Fail fast. The 60s default means a phone off the tailnet spins for a
        // full minute before admitting it can't connect. We already have
        // content to show; a quick "couldn't refresh" beats a long wait for
        // the same answer.
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        // Staleness is OUR cache's job. URLCache silently handing back a stale
        // body would make the "as of" timestamp lie, which is the one thing
        // this design must not do.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        self.cache = cache
    }

    /// The last good value, without touching the network. Returns nil on a
    /// first run or if the cached bytes no longer decode (an app update that
    /// changed the model, say) — in which case a refresh will repopulate it.
    public func cached<T: Decodable & Sendable>(_ type: T.Type, from url: URL) async -> Cached<T>? {
        guard let entry = await cache.read(for: url),
              let value = try? JSONDecoder().decode(type, from: entry.data)
        else { return nil }
        return Cached(value: value, fetchedAt: entry.fetchedAt)
    }

    /// Fetch, validate, decode, and only then replace the cache.
    @discardableResult
    public func refresh<T: Decodable & Sendable>(
        _ type: T.Type,
        from url: URL,
        expectedSchema: Int
    ) async throws -> Cached<T> {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw FeedError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FeedError.malformed("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedError.badStatus(http.statusCode)
        }

        // Check the schema BEFORE the full decode, so an incompatible feed
        // reports what is actually wrong rather than an inscrutable
        // keyNotFound buried three levels down.
        guard let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data) else {
            throw FeedError.malformed("no schema field — is this the right URL?")
        }
        guard envelope.schema == expectedSchema else {
            throw FeedError.unsupportedSchema(found: envelope.schema, supported: expectedSchema)
        }

        let value: T
        do {
            value = try JSONDecoder().decode(type, from: data)
        } catch {
            throw FeedError.malformed(String(describing: error))
        }

        let fetchedAt = await cache.write(data, for: url) ?? Date()
        return Cached(value: value, fetchedAt: fetchedAt)
    }
}
