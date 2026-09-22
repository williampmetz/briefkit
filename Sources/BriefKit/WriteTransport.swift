import Foundation

/// The HTTP half of a write: build the request, send it, turn every way it
/// can go wrong into a `WriteError`.
///
/// Moved here from `HydrationClient` when Daily Reflections needed the same
/// plumbing. Each app keeps its own small client that knows its endpoints and
/// bodies; this knows only JSON over HTTP and how FastAPI reports errors.
///
/// No retry here, on purpose. Whether a failure should be queued, surfaced or
/// dropped is the caller's decision — in practice the `Outbox`, via
/// `WriteError.disposition`.
public actor WriteTransport {
    private let session: URLSession
    private let baseURL: URL

    public init(baseURL: URL, timeout: TimeInterval = 10) {
        let config = URLSessionConfiguration.default
        // Same reasoning as FeedClient: the 60s default means a phone off the
        // tailnet hangs for a full minute before admitting it can't connect.
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.baseURL = baseURL
    }

    /// Send `body` as JSON and decode the reply as `Value`.
    public func send<Body: Encodable & Sendable, Value: Decodable & Sendable>(
        _ path: String, method: String, body: Body, decoding: Value.Type
    ) async throws -> Value {
        var request = self.request(path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw WriteError.malformed("couldn't encode the request: \(error)")
        }
        let data = try await perform(request)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw WriteError.malformed(String(describing: error))
        }
    }

    /// Send a bodiless request whose reply is ignored — a DELETE.
    public func sendNoContent(_ path: String, method: String) async throws {
        _ = try await perform(request(path, method: method))
    }

    /// RFC 3339, whole seconds, UTC — the same contract the servers emit on
    /// the way out, applied on the way in.
    ///
    /// UTC rather than the device's offset: the servers store `timestamptz`,
    /// only the instant matters, and `Z` is unambiguous even for a phone that
    /// changes timezone mid-day. What it must NOT be is a naive timestamp —
    /// the servers reject those, precisely so a late-evening write can't be
    /// silently reinterpreted into the wrong day.
    public nonisolated static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    // MARK: - Plumbing

    private func request(_ path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WriteError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw WriteError.malformed("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WriteError.rejected(status: http.statusCode, detail: Self.detail(from: data))
        }
        return data
    }

    /// FastAPI puts the useful part in `{"detail": ...}` — a string for a
    /// raised HTTPException, an array of objects for a validation failure.
    ///
    /// Anything else returns "", never the raw body: a 404 from nginx is an
    /// HTML page, and a 4xx's detail is shown to the reader as-is.
    static func detail(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"]
        else { return "" }
        if let text = detail as? String { return text }
        if let items = detail as? [[String: Any]] {
            return items.compactMap { $0["msg"] as? String }.joined(separator: "; ")
        }
        return ""
    }
}
