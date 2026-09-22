import Foundation

/// Why a write didn't land.
///
/// Deliberately separate from `FeedError`, which describes a *read*: it
/// carries a schema-mismatch case that makes no sense for a write, and a read
/// failure never needs the three-way disposition below.
///
/// Moved here from `hydration/ios/` when Daily Reflections became the second
/// app to write offline. Every case and every disposition is unchanged.
public enum WriteError: Error, Sendable {
    /// Couldn't reach the host at all. On a tailnet-only deployment this is
    /// the ORDINARY case — the phone is off the tailnet — not an alarm.
    case unreachable(String)
    /// Reached the server; it said no. `detail` is FastAPI's `detail` text,
    /// or empty if the body wasn't a FastAPI error.
    case rejected(status: Int, detail: String)
    /// Reached the server; couldn't make sense of the reply.
    case malformed(String)

    public var isOffline: Bool {
        if case .unreachable = self { return true }
        return false
    }

    /// What an outbox should do with a write that failed this way.
    ///
    /// Three answers rather than two, and the third is the one that matters.
    /// "Retryable vs permanent" is not enough, because retryable failures come
    /// in two kinds that must be treated oppositely:
    ///
    /// - `.transient` — we never got a real answer about THIS request. The
    ///   phone is off the tailnet, or nginx answered because the app
    ///   container behind it is down (502/503/504), or we were told to slow
    ///   down. None of that says anything about the item, so it is retried
    ///   forever and never counts towards parking it. This is the rule that
    ///   stops a week off the tailnet from parking every queued write: a
    ///   naive "give up after N attempts" would do exactly that.
    ///
    /// - `.itemFailure` — the app itself ran this request and blew up (a 500),
    ///   or answered with something unreadable. That might be a bad moment or
    ///   might be this particular item, so it is retried with backoff but
    ///   counted, and parked after `OutboxPolicy.parkAfterItemFailures`.
    ///   Without the cap, one item the server always chokes on would sit at
    ///   the head of the queue and block everything behind it forever.
    ///
    /// - `.park` — the request is wrong (a 4xx) and will be just as wrong in
    ///   an hour. Parked immediately, shown to the reader, never retried
    ///   automatically.
    ///
    /// 409 needs no case: both servers answer a replayed `client_id` with 200
    /// and the stored row, not a conflict, so idempotency never reaches here.
    public var disposition: Disposition {
        switch self {
        case .unreachable:
            return .transient
        case .rejected(let status, _):
            switch status {
            case 502, 503, 504, 408, 429: return .transient
            case 500...599:               return .itemFailure
            default:                      return .park
            }
        case .malformed:
            // A 2xx we couldn't decode most likely means the write LANDED and
            // the reply was mangled. Retrying is safe — creates are idempotent
            // and deletes succeed on nothing — and if it really did land, the
            // next feed refresh sees the client_id and clears it regardless.
            return .itemFailure
        }
    }

    public enum Disposition: Sendable, Equatable {
        case transient, itemFailure, park
    }

    /// Kept for readability at call sites that only need the yes/no.
    public var isRetryable: Bool { disposition != .park }
}

extension WriteError: LocalizedError {
    /// Shown to the reader — a parked write carries this as its reason.
    ///
    /// A 4xx shows the server's own `detail` when there is one. Before the
    /// move this file special-cased hydration's 404 as "That beverage type no
    /// longer exists"; the server already says "Unknown beverage type", and
    /// Reflections says "Unknown prompt 'x'", so the generic rule serves both
    /// without the package knowing what either app is about.
    public var errorDescription: String? {
        switch self {
        case .unreachable:
            return "Couldn't reach the server."
        case .rejected(let status, let detail) where (400..<500).contains(status) && !detail.isEmpty:
            return detail
        case .rejected(422, _):
            return "The server rejected that."
        case .rejected(let status, _):
            return "The server returned an error (\(status))."
        case .malformed:
            return "The server's reply couldn't be read."
        }
    }
}
