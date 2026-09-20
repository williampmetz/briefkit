import Foundation

/// A decoded value plus the moment it was last successfully fetched.
///
/// Two different freshness questions matter in an offline-first app, and they
/// are easy to conflate:
///
/// - `fetchedAt` — when this client last *reached the server*. If it is old,
///   you are looking at a copy and may be missing something newer.
/// - the payload's own `generatedAt` — when the server *built* the briefing.
///   This is what an "as of" line should show, because it is what the reader
///   actually cares about.
///
/// A briefing generated at 5:30am and fetched at 5:31am is fresh. The same
/// briefing fetched again at 9pm is still the 5:30am briefing: `fetchedAt`
/// moved, `generatedAt` did not. Showing `fetchedAt` as "as of" would tell the
/// reader their news is current when it is sixteen hours old.
public struct Cached<Value: Sendable>: Sendable {
    public let value: Value
    public let fetchedAt: Date

    public init(value: Value, fetchedAt: Date) {
        self.value = value
        self.fetchedAt = fetchedAt
    }

    public var age: TimeInterval { Date().timeIntervalSince(fetchedAt) }

    public func isStale(after interval: TimeInterval) -> Bool { age > interval }
}
