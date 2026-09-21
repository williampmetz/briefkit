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

# Not here yet: the write path

Everything above assumes **read-only**: fetch, cache, display. Morning Edition
never sends anything back.

Hydration does. Logging a drink while offline has to be kept locally and
submitted when connectivity returns, which is a genuinely harder problem than
cache-first reads and deliberately **not** designed here — building it
speculatively, against no real caller, is how you get the wrong abstraction.

Sketch of what it will need, so the shape isn't rediscovered from scratch:

- A **durable outbox**: pending mutations written to disk before the UI
  acknowledges them, drained on connectivity.
- **Client-generated idempotency keys.** A retry whose first attempt actually
  succeeded must not log the drink twice. This is a server change too — the
  endpoint has to recognise a repeated key.
- **Optimistic UI with a pending state.** The count goes up immediately; the
  entry is visibly unsynced until it isn't.
- **Ordering and clock skew.** The client's timestamp is the real one; the
  server should not stamp arrival time.
- **A poison-message escape.** A mutation the server keeps rejecting must not
  block the queue forever or retry silently until the end of time.

The reads side of hydration can use `FeedClient` today, unchanged.

## Where the write path is being built, and when it moves here

**In `hydration/ios/`, not here — for now.** The same rule that governed
FeedClient's extraction governs this one: you cannot design a good shared API
from one caller. FeedClient came here when hydration became the second
consumer of a cache layer that already worked. An outbox has exactly one
caller today, and building it here first would bake hydration's particular
shape — ounces, beverage types, an effective-dated goal — into an API that
Daily Reflections then has to fight.

**The extraction trigger, so it isn't re-litigated:** when a second app needs
to write while offline. Daily Reflections is the obvious candidate — it posts
entries the same way. At that point the outbox moves here, this section is
replaced by real documentation, and the sketch above stops being speculation
because there are two callers to generalise from.

Until then the sketch stands as the specification, and hydration's
implementation is the reference. Anything it learns that the sketch got wrong
belongs up there, in this file, even while the code lives elsewhere — the
point of writing it down early was to not rediscover it.

### What building it taught, that the sketch above missed

Implemented in `hydration/ios/Hydration/Hydration/Outbox.swift`, with tests
in `hydration/ios/Harness/`. Three things the five bullets didn't say:

- **"Retryable" is two categories, and they must be treated oppositely.**
  Offline, a gateway 502/503/504, a 408 or a 429 say nothing about the
  item — retry forever, never count it. A 500 means the app ran THIS request
  and blew up — retry with backoff, but count it and park it eventually. A
  single "give up after N attempts" rule would park every queued drink after a
  week off the tailnet, which is the ordinary case this whole package exists
  for. That split is what the poison-message bullet actually requires.
- **A queued operation needs its own id, separate from the entry's.** A create
  and the delete that undoes it are two operations on one entry. Keying the
  queue on the entry's client id meant a successful create removed its own
  pending delete, so a drink logged and deleted offline came back on
  reconnect. The tests caught it; reading the code had not.
- **Offline makes the day boundary real.** Online, a cached feed is always
  today's. Offline overnight it is yesterday's, and showing it as-is greets
  you with last night's totals. Anything that buckets by day has to compare
  against the current date in the SERVER's timezone, and a feed from an
  earlier day contributes nothing but its schedule — which is why hydration's
  feed carries tomorrow's.
