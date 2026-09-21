import Foundation

/// Date parsing for feeds in this family.
///
/// Extracted from `morning-edition/ios/Morning Edition/MorningEditionFeed.swift`
/// when hydration became the second client needing it — the same trigger that
/// brought `FeedClient` here. Two copies of a date parser would be two places
/// to fix the next time a server emits something `ISO8601DateFormatter`
/// dislikes, and that has already happened once (ESPN, seconds omitted).
///
/// ## Why feeds decode dates as `String` with a computed `Date?`
///
/// It looks clumsy and it is deliberate, for three reasons:
///
/// 1. `JSONDecoder` has exactly ONE date strategy per decoder, but these feeds
///    mix RFC 3339 timestamps with plain `YYYY-MM-DD` dates. No single
///    strategy handles both.
/// 2. Absent values arrive as `""`, which every built-in strategy throws on —
///    turning a missing optional field into a whole-payload failure.
/// 3. A single malformed date must never fail the entire decode. That would
///    mean falling back to yesterday's cache over one bad field, which is
///    exactly the failure offline-first exists to prevent.
///
/// Both parsers therefore return nil rather than throwing. The cost of that
/// choice is that a server emitting a shape these don't accept produces a
/// silently missing date rather than an error, so servers are expected to
/// normalise on the way out — RFC 3339, whole seconds, explicit offset.
public nonisolated enum FeedDate {
    /// Formatters are expensive to build, so these are created once.
    ///
    /// `nonisolated(unsafe)` because they are static, not Sendable, and this
    /// type is nonisolated. Apple documents `DateFormatter` as thread-safe on
    /// iOS 7 and later once configured, and nothing here mutates them after
    /// the initializer runs — only `date(from:)` is ever called. Building one
    /// per call is measurably slower across a couple of hundred items for no
    /// real safety gain.
    nonisolated(unsafe) private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Fallback for servers that emit fractional seconds. Note that this
    /// option is built for three fractional digits; six (Postgres' native
    /// microsecond precision, say) is not reliably parsed, which is why the
    /// feed contract asks servers to emit whole seconds rather than relying
    /// on this.
    nonisolated(unsafe) private static let rfc3339Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        // A fixed format needs a fixed locale, or a device set to a
        // non-Gregorian calendar parses these wrong.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Returns nil rather than throwing — a bad date costs you one field, not
    /// the whole payload.
    public static func parse(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        return rfc3339.date(from: text) ?? rfc3339Fractional.date(from: text)
    }

    public static func parseDateOnly(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        return dateOnly.date(from: text)
    }
}
