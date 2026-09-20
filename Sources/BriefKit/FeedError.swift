import Foundation

public enum FeedError: Error, Sendable {
    /// The host could not be reached at all.
    ///
    /// On a tailnet-only deployment this is the ORDINARY case, not an
    /// exception — the phone is simply off the tailnet. UI should render it as
    /// a quiet "couldn't refresh" beside the cached content, never as an
    /// alarm. See `isOffline`.
    case unreachable(String)

    /// Reached the server, got a non-2xx. A 404 here usually means the feed
    /// has not been generated yet, not that anything is broken.
    case badStatus(Int)

    /// The feed's `schema` is not one this build understands.
    ///
    /// Refusing beats decoding partially. The generator runs from cron and the
    /// app is installed on a phone, so they drift; a field whose *meaning*
    /// changed would render something subtly and confidently wrong, which is
    /// worse than showing nothing.
    case unsupportedSchema(found: Int, supported: Int)

    case malformed(String)
}

public extension FeedError {
    /// True for the everyday "not on the tailnet" case, as opposed to
    /// something the reader should actually worry about.
    var isOffline: Bool {
        if case .unreachable = self { return true }
        return false
    }
}

extension FeedError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Couldn't reach the server."
        case .badStatus(let code):
            return code == 404
                ? "The feed isn't published yet."
                : "The server returned an error (\(code))."
        case .unsupportedSchema(let found, let supported):
            return "This feed uses format \(found); this app understands \(supported). Update the app."
        case .malformed:
            return "The feed couldn't be read."
        }
    }
}
