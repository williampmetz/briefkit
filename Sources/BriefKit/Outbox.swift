import Foundation

// MARK: - What an app supplies

/// One kind of write an app can queue. The app defines these — typically an
/// enum with a create case and one or two delete cases — and the outbox
/// handles everything else: durability, ordering, retry, parking.
///
/// The operation is stored on disk inside the queue file, so its `Codable`
/// shape is a file format. Add fields as optionals; rename nothing.
public protocol OutboxOperation: Codable, Sendable {
    /// True if this operation creates the entry named by `targetClientId`.
    /// The outbox needs to know which queued operations are creates for two
    /// things only: cancelling one before it's sent, and clearing one the
    /// feed shows already landed.
    var isCreate: Bool { get }

    /// The client-generated id of the entry this operation is about, or nil
    /// when it's addressed some other way (a delete by server id, for a row
    /// written from the web).
    var targetClientId: UUID? { get }
}

// MARK: - A queued write

/// One queued write.
///
/// Stored on disk, so its shape is a file format: add fields as optionals
/// with defaults, and bump `OutboxPolicy.fileVersion` for anything else. A
/// queue that no longer decodes is moved aside rather than deleted — see
/// `Outbox.load()`.
///
/// Generic over the app's operation type, which changes nothing on disk: the
/// JSON is exactly what hydration's non-generic version wrote, so a queue
/// left on the phone by the old build still loads. The harness proves this
/// against a file captured from that build.
///
/// ## Two ids, and why they must never be the same field
///
/// `id` is this queued OPERATION. `operation.targetClientId` is the ENTRY it
/// concerns. They look interchangeable and are not: a create and the delete
/// that later undoes it are two operations on one entry, so they share a
/// target and must have different ids.
///
/// The first version keyed the queue on the entry's client id. The outbox
/// tests caught what that did: when the create succeeded, "remove this item"
/// removed every item with that client id — including the queued delete —
/// so logging a drink offline and deleting it before reconnecting silently
/// brought the drink back. Exactly the case delete-by-client-id exists for.
public struct OutboxItem<Operation: OutboxOperation>: Codable, Sendable, Identifiable {
    /// This operation's own identity. Never the entry's client id.
    public let id: UUID
    public let operation: Operation
    public let enqueuedAt: Date
    /// Failures where the server saw THIS request and choked. Transient
    /// failures (offline, gateway down) never increment it — see
    /// `WriteError.Disposition`.
    public var itemFailures: Int = 0
    /// The most recent failure, for display. Cleared on success.
    public var lastError: String?
    /// Non-nil once the item has been taken out of automatic retry.
    public var parkedReason: String?

    public init(operation: Operation, id: UUID = UUID(), enqueuedAt: Date = Date()) {
        self.id = id
        self.operation = operation
        self.enqueuedAt = enqueuedAt
    }

    public var isParked: Bool { parkedReason != nil }
}

// MARK: - Retry policy

/// The outbox's constants. A namespace of its own because Swift doesn't
/// allow static stored properties on a generic type.
///
/// These are choices, not measurements, so their CONSEQUENCES are written
/// down instead — computed, not estimated:
///
///     failure   wait before next    elapsed so far
///        1           5s                  0s
///        2          10s                  5s
///        3          20s                 15s
///        4          40s                 35s
///        5          80s                 75s   (1.2 min)
///        6         160s                155s   (2.6 min)
///        7         300s                315s   (5.2 min)
///        8         300s                615s  (10.2 min)  <- parked here
///
/// So an item the server keeps refusing is parked after roughly ten minutes
/// of the server being UP and saying no to it — long enough to ride out a
/// container restart or a deploy running its migration, short enough that it
/// doesn't block the queue for an afternoon. Offline time never counts
/// towards this; only item failures do.
///
/// The cap governs only the unattended retry loop. Opening the app, making
/// an entry, pulling to refresh, or the network changing all drain
/// IMMEDIATELY, because backoff exists to stop an app hammering a dead
/// server in a loop, not to make a person wait.
public enum OutboxPolicy {
    public static let baseDelay: TimeInterval = 5
    public static let maxDelay: TimeInterval = 300
    public static let parkAfterItemFailures = 8

    /// Bumped on any change to the queue file's shape that old code couldn't
    /// read. Still 1: making the item generic did not change the file.
    public static let fileVersion = 1
}

// MARK: - The queue

/// The durable queue of writes that haven't reached the server yet.
///
/// Where each of the five requirements this README sketched before any of it
/// existed now lives:
///
/// 1. **Durable** — `enqueue` writes to disk before it returns; an app should
///    only show a pending row once that has happened.
/// 2. **Idempotency keys** — the entry's client id, carried in the operation
///    and generated on the phone; the server treats a repeat as a no-op.
/// 3. **Optimistic UI** — the app's store merges `snapshot()` into what the
///    reader sees.
/// 4. **Ordering and clock skew** — FIFO drain that stops on the first
///    transient failure, and the entry's time captured when it's made, never
///    when it's sent.
/// 5. **Poison-message escape** — `.park`, and
///    `OutboxPolicy.parkAfterItemFailures`.
///
/// The drain takes the network call as a closure, so nothing in here knows
/// what any app writes or where.
public actor Outbox<Operation: OutboxOperation> {
    public typealias Item = OutboxItem<Operation>

    private struct File: Codable {
        var version: Int
        var items: [Item]
    }

    public private(set) var items: [Item] = []
    /// Set if the last write to disk failed. The queue is still held in
    /// memory and still drains; the reader should be told it may not survive
    /// a restart.
    public private(set) var persistError: String?
    /// Set if an unreadable queue file was found and moved aside at launch.
    public private(set) var recoveredFrom: URL?

    private var didLoad = false
    private var consecutiveFailures = 0
    private var nextAttemptAt: Date?
    private var isDraining = false
    /// The item currently on the wire. Actors are REENTRANT: while `drain`
    /// awaits the network, other calls on this actor run. Anything that
    /// would remove an item must check this first, or it can pull a create
    /// out from under a request that is already landing on the server.
    private var inFlight: UUID?

    private let fileURL: URL

    // ISO 8601 rather than the default seconds-since-2001, so the file is
    // readable by a person debugging it. Sub-second precision is dropped,
    // which costs nothing: the servers store whole seconds anyway. Instance
    // properties, not static, because the actor is generic.
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// `directoryName` is the folder under Application Support. Each app has
    /// its own sandbox, so the default is safe; hydration's queue has always
    /// lived at "Outbox" and must keep doing so or an upgrade would strand it.
    public init(directoryName: String = "Outbox") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Application Support, not Caches — for the same reason as DiskCache,
        // and more so: the cache holds a copy of server data, but this holds
        // the ONLY copy of writes the server hasn't seen yet.
        fileURL = directory.appendingPathComponent("queue.json")

        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder = e
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        decoder = d
    }

    // MARK: Persistence

    /// Load the queue from disk. Call once at launch, before anything is
    /// enqueued.
    ///
    /// A file that won't decode is renamed, never deleted. It holds writes
    /// nobody else has a record of, and "the app updated and quietly threw
    /// away what you entered on the train" is not an acceptable failure.
    public func load() {
        // Once only. A second read would REPLACE the in-memory queue with
        // the file's, dropping anything enqueued in between — and at launch
        // the initial load and the scene becoming active race each other.
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: fileURL) else { return }  // first run
        do {
            let file = try decoder.decode(File.self, from: data)
            guard file.version == OutboxPolicy.fileVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            items = file.items
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = fileURL.deletingLastPathComponent()
                .appendingPathComponent("queue.unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            recoveredFrom = aside
            items = []
        }
    }

    private func persist() {
        do {
            let data = try encoder.encode(File(version: OutboxPolicy.fileVersion, items: items))
            // Atomic: a half-written queue after a crash would fail to decode
            // and be moved aside, which is safe but loses the lot from view.
            try data.write(to: fileURL, options: .atomic)
            persistError = nil
        } catch {
            persistError = error.localizedDescription
        }
    }

    // MARK: Mutations

    public func enqueue(_ item: Item) {
        items.append(item)
        persist()
    }

    /// Take a queued create back before it is sent — deleting an entry that
    /// never reached the server.
    ///
    /// Returns false if it's already on the wire. The caller must then
    /// enqueue a delete instead, which will run after the create lands; the
    /// entry exists on the server for a moment, but removing an in-flight
    /// create from the queue would leave it there permanently.
    public func cancelCreate(_ clientId: UUID) -> Bool {
        guard let index = items.firstIndex(where: {
                  $0.operation.isCreate && $0.operation.targetClientId == clientId
              }),
              inFlight != items[index].id
        else { return false }
        items.remove(at: index)
        persist()
        return true
    }

    /// Drop a parked item the reader has chosen to abandon. By OPERATION id:
    /// discarding a failed create must not also discard anything else queued
    /// against the same entry.
    public func discard(_ itemId: UUID) {
        guard inFlight != itemId else { return }
        items.removeAll { $0.id == itemId }
        persist()
    }

    /// Put a parked item back into automatic retry, with a clean slate.
    public func unpark(_ itemId: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        items[index].parkedReason = nil
        items[index].itemFailures = 0
        items[index].lastError = nil
        persist()
    }

    /// The feed reported these client ids, so any queued CREATE for them has
    /// demonstrably landed — even if this queue never heard back, because
    /// the response was lost or the app was killed mid-request. Only creates:
    /// a queued delete must still run.
    public func removeConfirmedCreates(_ confirmed: Set<UUID>) {
        let before = items.count
        items.removeAll { item in
            guard item.operation.isCreate, let target = item.operation.targetClientId else { return false }
            return confirmed.contains(target)
        }
        if items.count != before { persist() }
    }

    // MARK: Draining

    public struct DrainResult: Sendable {
        /// What landed, in order. A store holds on to these until a feed
        /// refresh reflects them, so an entry doesn't blink out of the list
        /// in the gap between "the server has it" and "we've re-read the
        /// server" — or stay missing if that re-read fails.
        public var sent: [Item] = []
        public var succeeded: Int { sent.count }
        public var parked = 0
        /// True if the drain stopped because it couldn't get a real answer.
        public var hitTransient = false
    }

    /// Send queued writes in order until the queue is empty or a failure
    /// says to stop.
    ///
    /// - A **transient** failure stops the drain. Whatever is wrong will be
    ///   wrong for the next item too, and order matters: a delete must never
    ///   overtake the create it refers to.
    /// - A **parked** item is stepped over, and the drain continues. Its
    ///   problem is its own, and letting it block the queue is precisely the
    ///   poison-message failure the policy exists to prevent. Stepping over
    ///   is safe for ordering: every operation is idempotent against a create
    ///   that never happened.
    ///
    /// `respectBackoff` is false for anything a person or the network
    /// triggered, and true only for the unattended retry loop.
    ///
    /// `send` should throw `WriteError`. Anything else is treated as
    /// `.malformed` — an item failure, retried with backoff, eventually
    /// parked.
    public func drain(respectBackoff: Bool,
                      send: @Sendable (Item) async throws -> Void) async -> DrainResult {
        var result = DrainResult()
        guard !isDraining else { return result }
        if respectBackoff, let next = nextAttemptAt, next > Date() { return result }
        isDraining = true
        defer { isDraining = false }

        var attempted: Set<UUID> = []
        // Re-scanned every pass rather than indexed, because `items` can
        // change during each await: enqueue appends, and a feed refresh can
        // remove confirmed creates.
        while let item = items.first(where: { !$0.isParked && !attempted.contains($0.id) }) {
            attempted.insert(item.id)
            inFlight = item.id
            let outcome: Result<Void, WriteError>
            do {
                try await send(item)
                outcome = .success(())
            } catch let error as WriteError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.malformed(error.localizedDescription))
            }
            inFlight = nil

            switch outcome {
            case .success:
                items.removeAll { $0.id == item.id }
                consecutiveFailures = 0
                nextAttemptAt = nil
                result.sent.append(item)
                persist()

            case .failure(let error):
                // Found again by id: it may have been removed while we were
                // waiting (a refresh saw it land), in which case its failure
                // is moot.
                guard let index = items.firstIndex(where: { $0.id == item.id }) else {
                    continue
                }
                let reason = error.localizedDescription
                items[index].lastError = reason

                switch error.disposition {
                case .park:
                    items[index].parkedReason = reason
                    result.parked += 1
                    persist()
                    continue

                case .itemFailure:
                    items[index].itemFailures += 1
                    if items[index].itemFailures >= OutboxPolicy.parkAfterItemFailures {
                        items[index].parkedReason =
                            "Stopped retrying after \(OutboxPolicy.parkAfterItemFailures) server errors: \(reason)"
                        result.parked += 1
                        persist()
                        continue
                    }
                    scheduleRetry()
                    persist()
                    return result

                case .transient:
                    scheduleRetry()
                    result.hitTransient = true
                    persist()
                    return result
                }
            }
        }
        return result
    }

    private func scheduleRetry() {
        consecutiveFailures += 1
        let delay = min(OutboxPolicy.maxDelay,
                        OutboxPolicy.baseDelay * pow(2, Double(consecutiveFailures - 1)))
        nextAttemptAt = Date().addingTimeInterval(delay)
    }

    // MARK: Reading

    /// Seconds until the retry loop should next try, or nil if there is
    /// nothing it could send.
    public func secondsUntilNextAttempt() -> TimeInterval? {
        guard items.contains(where: { !$0.isParked }) else { return nil }
        guard let next = nextAttemptAt else { return 0 }
        return max(0, next.timeIntervalSinceNow)
    }

    public func snapshot() -> [Item] { items }
}
