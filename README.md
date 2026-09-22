# BriefKit

Shared client plumbing for the mini-apps: fetch a JSON feed, cache it to disk,
survive being offline. Plus — below — the iOS conventions this family of apps
follows, most of which were learned by getting them wrong first.

Extracted from `morning-edition/ios/Packages/BriefKit` when hydration became
the second consumer. That was the agreed trigger: you cannot design a good
shared API from one caller, and two copies of a cache layer diverge quietly.

## The design rule

**A failed refresh never damages the cache.** Every failure path in
`FeedClient.refresh` returns before the write, so the last good copy survives.

On a tailnet-only deployment, being unable to reach the server is the ORDINARY
case — the phone is simply off the tailnet — not an exception. Losing
yesterday's data over it would be the worst outcome available. Everything else
follows from that:

- The cache lives in **Application Support, not Caches**. The system evicts
  Caches under storage pressure, and evicting the only copy is exactly the
  failure this prevents.
- Writes are **atomic**. A half-written file after a crash looks like
  corruption rather than absence.
- `URLSession` uses `.reloadIgnoringLocalCacheData` and a 10s timeout.
  Staleness is this cache's job; `URLCache` silently returning a stale body
  would make the "as of" timestamp lie.
- `FeedError.isOffline` separates "not on the tailnet" from something worth
  worrying about, so the UI can stay quiet about the common case.

## Two timestamps, not one

- `Cached.fetchedAt` — when the client last reached the server.
- the payload's own `generatedAt` — when the server built the data.

Show `generatedAt` as "as of". Data generated at 5:30am and re-fetched at 9pm
is still the 5:30am data; showing the fetch time tells the reader it's current
when it is sixteen hours old.

## Using it

Xcode → File → Add Package Dependencies… → **Add Local…** → select this
folder. Then add `BriefKit` to the app target's frameworks.

**Do not also drag the source files into the app target.** If the same type
exists in both the app module and an imported one, Swift silently prefers the
LOCAL one — the app compiles, `import BriefKit` becomes dead weight, and edits
to the package have no effect until you build app number three against a copy
that has quietly diverged.

---

# iOS conventions

Every item here cost at least one failed build or one crash. The reasoning
matters more than the rule, because the rules look arbitrary without it.

### Mark model types `nonisolated`

These targets build with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which
makes every declaration implicitly `@MainActor`. Good for UI code, wrong for a
data model: `FeedClient` is generic over `Decodable & Sendable` and runs off
the main actor, and a main-actor-isolated conformance cannot satisfy a
`Sendable` requirement.

The symptom is a pile of errors pointing at *BriefKit's* constraint while the
cause sits in your model file:

    Main actor-isolated conformance of 'X' to 'Decodable' cannot satisfy
    conformance requirement for a 'Sendable' type parameter

Mark every type in the model file `nonisolated`, nested `CodingKeys` included.

### Never name a model type `Section`

SwiftUI exports a `Section` view. When a name exists in both the current module
and an imported one, Swift picks the **local** declaration — so a model type
called `Section` silently shadows SwiftUI's in every view file. The error is
unrecognisable:

    Trailing closure passed to parameter of type 'any Decoder'

Prefix model types that collide with SwiftUI or Foundation names. Sweep for
this before you write views, not after.

### Notification delegates: completion-handler variants only

Never the `async` ones. With the async form the framework resumes its own
completion work on whatever executor the continuation landed on — off the main
thread — then touches UIKit and dies:

    *** Assertion failure in -[SwiftUIApplication
        _performBlockAfterCATransactionCommitSynchronizes:]
    'Call must be made on main thread'

It only shows up on the launch a notification tap triggers, so it survives
casual testing. Implement `withCompletionHandler:` variants, mark the delegate
class `nonisolated` (the system calls it from a background thread), and call
the handler inside `Task { @MainActor in }`.

**Test the actual tap**, not just that the notification arrived.

### `@ScaledMetric` for any fixed dimension

A hard-coded column width is the one part of a layout that does not scale with
Dynamic Type. `@ScaledMetric(relativeTo: .subheadline) var width: CGFloat = 92`
ties it to the text size it holds.

### Use semantic fonts, and only caption genuine captions

`.body`, `.headline`, `.footnote` scale with the reader's iOS text size; fixed
point sizes don't. That's why these apps have no in-app text-size control — iOS
has one, system-wide, that honours accessibility sizes a bespoke A−/A+ never
would.

The hierarchy error worth avoiding: recaps, explanatory text and detail
paragraphs are *content*. Styling them `.caption` is what makes an app look
shrunken, and no amount of scaling fixes it.

### Drop macOS from Supported Destinations

The multiplatform template includes it. A sandboxed Mac app has **no network
access** without `com.apple.security.network.client`; iOS needs no such
entitlement. Running the Mac destination by accident produces a "server not
found" that looks like a networking bug and isn't.

Target → General → Supported Destinations → remove Mac and Vision Pro.

### Colours: dynamic pairs in code, contrast measured

Define light/dark values as dynamic `UIColor`s in a `Theme.swift`, not in the
asset catalog — both values sit in one reviewable file next to the reasoning,
instead of opaque JSON nobody reads.

**Measure the contrast.** A link blue chosen against near-white is unreadable
on dark. Morning Edition's own page carried a tag colour at 3.87:1 that failed
AA in *light* mode and nobody noticed for weeks. Target 4.5:1 for body text.

In dark mode use a warm near-black, not pure `#000` — newsprint, not a
terminal.

### Xcode cannot read `~/.ssh/config`

Its source control is built on libgit2, which ignores SSH host aliases, so a
`git@github.com-reponame:` remote fails with a hostname error. Use an
account-level key with a plain `git@github.com:` remote on the Mac, and keep
repo-scoped deploy keys on the server where blast radius actually matters. The
per-repo convention was written for the deploy target, not the laptop.

---

# The feed contract

What a server owes a client in this family. `morning-edition/lib/serialize.py`
is the reference implementation; its README has the full schema.

- **Raw values, not display strings.** Emit `2026-09-19T14:00:00-04:00`, not
  `2–3:30 PM`. A client that formats it gets the reader's locale, 24-hour
  preference and Dynamic Type accessibility for free — none of which a
  `strftime` call on the server knows about. Pass through strings that are
  genuinely upstream editorial content.
- **RFC 3339 with seconds and an explicit offset.** ESPN emits
  `2026-09-18T23:40Z` — legal ISO 8601, *not* legal RFC 3339 — and Swift's
  `ISO8601DateFormatter` rejects it. Normalise everything through
  `datetime.isoformat()`. An unparseable timestamp becomes `""`, never a guess.
- **`ok` and `errors` on every section.** A client that isn't told a source
  failed renders a confidently empty card. The no-fabrication rule only holds
  end to end if the failure travels with the data.
- **A `schema` integer at the top**, bumped on breaking changes only. The
  server runs from cron and the app lives on a phone; they *will* drift. A
  client should refuse a schema it doesn't recognise rather than decode
  partially and render something subtly wrong.
- **Decode dates as `String` with computed `Date?`.** `JSONDecoder` has one
  date strategy per decoder, feeds mix formats, absent values arrive as `""`
  which every built-in strategy throws on, and one malformed date must never
  cost the whole payload and send you back to yesterday's cache.

# Push notifications

`morning-edition/scripts/apns_push.py` is parameterised by environment
variables, so another app's notify script can call the same file.

**One `.p8` key covers every app under your team.** A new app needs its own App
ID, bundle ID and device token — not a new key.

`APNS_ENVIRONMENT=sandbox` for anything Xcode installed; production only for
TestFlight and the App Store. Getting this wrong yields `BadDeviceToken` and no
other clue, and it is the single most common way push setup fails.

---

# The write path

`Outbox`, `WriteTransport` and `WriteError`: queue a write durably, show it
at once, send it when the server is reachable, and never lose it or send it
twice. Built in `hydration/ios/` against one real caller, and moved here when
Daily Reflections became the second app to write offline — the trigger this
section used to name.

## What an app supplies

1. **An operation type** conforming to `OutboxOperation` — usually an enum
   with a create case and one or two delete cases. It reports `isCreate` and
   `targetClientId`, and is stored inside the queue file, so its `Codable`
   shape is a file format: add fields as optionals, rename nothing.
   `hydration/ios/Hydration/Hydration/HydrationOperation.swift` is the
   reference.
2. **A small client** over `WriteTransport` that knows its endpoints and
   bodies. `WriteTransport` does the HTTP: JSON in and out, every failure
   mapped to a `WriteError`, FastAPI's `detail` pulled out for display, and
   `WriteTransport.timestamp(_:)` for the RFC 3339 UTC form the servers
   require.
3. **A `send` closure** passed to `Outbox.drain`, switching on the operation
   and calling the client.
4. **Typealiases with names of their own** — `typealias HydrationOutbox =
   Outbox<HydrationOperation>`, `typealias QueuedWrite =
   OutboxItem<HydrationOperation>` — never an app type called `Outbox` or
   `OutboxItem`, which is the shadowing trap under "Using it".

The server's half is the same in every app: a nullable `client_id UUID
UNIQUE` column (a replay returns the stored row with 200), a client-supplied
timestamp that must carry an offset and has no lower bound, and delete by
`client_id`. See `hydration/migrations/002_offline_writes.sql` and
`daily-reflections/migrations/003_offline_writes.sql`.

## The rules, and why

- **Durable before visible.** `enqueue` writes to Application Support before
  it returns. Show a pending row only after that.
- **Two ids.** An item's `id` is the queued OPERATION; the entry's client id
  lives in the operation. A create and the delete that undoes it share a
  target and must not share an id — keying the queue on the entry meant a
  successful create removed its own pending delete, so a drink logged and
  deleted offline came back on reconnect. The tests caught it; reading the
  code had not.
- **Three dispositions, not two** (`WriteError.disposition`). Offline, a
  gateway 502/503/504, a 408 or a 429 say nothing about the item: retry
  forever, never count it. A 500 or an unreadable reply means the app ran
  THIS request and choked: retry with backoff, count it, park it after
  `OutboxPolicy.parkAfterItemFailures`. Any other 4xx parks immediately. A
  single "give up after N" rule would park every queued write after a week
  off the tailnet, which is the ordinary case this package exists for.
- **Drain stops on transient, steps over parked.** Stopping preserves order —
  a delete must never overtake its create. Stepping over keeps one bad item
  from wedging the queue, and is safe because every operation is idempotent
  against a create that never happened.
- **Backoff is for the unattended loop only.** Anything a person or the
  network triggers drains immediately (`respectBackoff: false`).
- **An unreadable queue file is renamed, never deleted.** It holds the only
  copy of writes the server hasn't seen.
- **Offline makes the day boundary real.** A cached feed from an earlier day
  must contribute no rows to "today", and "today" is the SERVER's timezone.
  This lives in each app's store, not here, but every app that buckets by day
  meets it.

## Reference implementation and tests

`hydration/ios/Hydration/Hydration/HydrationStore.swift` is the worked
example of a store driving an outbox: the optimistic merge, holding sent
writes until a refresh that began after them has applied, and ticketing
refreshes so an older response can't roll the screen back.

The tests are in `hydration/ios/Harness/` (`OutboxTests`, run by
`run-linux.sh`). They import BriefKit as a module, so they exercise the
package through its public API. Scenario 18 loads
`Harness/Fixtures/queue-pre-briefkit.json`, a queue written by the
non-generic hydration build, to prove the move changed nothing on disk.

`OutboxPolicy` holds the constants because a generic type can't have static
stored properties. Its doc comment has the backoff table, worked out rather
than estimated.
