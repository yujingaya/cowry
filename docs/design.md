# Cowry Design

> Status: draft (revision 3) · 2026-09-27
> Scope: detailed design for phase 1 (local-only macOS app); direction for phases 2–3. Purpose, UX principles and screen design live in [ux.md](ux.md).

## 0. Summary

Cowry is an Apple-native, local-first, double-entry ledger app.

> **Keep an accurate record of your money, and get an instant answer to any question you ask of it. The record is entirely yours.** ([ux.md §0](ux.md))

- **One language: Swift.** An AppKit app plus the `CowryKit` package; storage is GRDB (SQLite).
- **Explore the whole ledger without friction.** Scroll, filter and search ten years of entries with no paging. Lists are virtualized `NSTableView`s.
- **Double-entry model, everyday words.** The default UI shows money flowing ("Visa → Dining"). Accounting terms are a setting.
- **The ledger is a library.** Like Photos, the app manages one ledger and opens it directly. "Show in Finder" and "Export Backup" make ownership visible.
- **The UI and the ledger runtime are separate.** The UI only knows the runtime's public API: commands, snapshot reads and a change stream. Module boundaries and access control make the compiler enforce this.
- **The op log is the single source of truth.** Every change is recorded as an immutable op; tables are the result of replaying the log. The log itself is the edit history.
- **Sync rebases onto a central linear log.** Conditional append (CAS) orders the remote main log; local ops not yet in main are reapplied on top of the new main.
- **Conflicts are resolved, not refused, and then recorded.** Deterministic default policies (field-group 3-way merge, last writer by authoring time, …) resolve them, and the outcome goes into a conflict log where people can revisit it. Structural invariants never break.
- **A hash chain and a state digest verify the ledger.** The hash chain detects tampering and corruption of the log; the state digest detects devices whose replays diverge.
- **Multi-currency.** Amounts are recorded in their own commodity and valued in the primary currency at query time. Entries mixing commodities balance per commodity through a conversion account.
- **The transport sits behind a protocol.** Phase 1 is local-only, with sync logic tested against an in-memory remote. CloudKit arrives in phase 2.

## 1. Principles

1. **Local-first.** The SQLite file on the device is always a complete copy. The cloud is a relay, not the owner. Everything works without a network.
2. **Do one thing well.** The app records, verifies, queries, values and syncs. Bank connections, budgeting and investment analysis are out of scope. Imports take the output of external tools (phase 3).
3. **Structural invariants are enforced by structure.** No path may produce an unbalanced entry, a reference to a nonexistent account, or a cycle in the account tree.
4. **Ops carry decisions; replay makes none.** Anything whose outcome could differ between runs is settled when the op is authored and recorded in it.
   - Examples: the current time, new UUIDs, generated conversion postings, conflict resolutions.
   - Replay is a pure function `(state, op) → state`.
5. **Facts are separate from caches.** Only facts people enter go into the op log and sync. Price caches, indexes and totals are local and can always be rebuilt.
6. **Strict when authoring, lenient when merging.** Local input is checked against every rule. Merging with other devices refuses nothing: deterministic policies resolve conflicts and the outcome is recorded.

## 2. Architecture

### 2.1 Modules

```
CowryKit (Swift Package)
├─ LedgerCore     Domain types · op definitions · validation · merge policy · amounts · digests
│                 Foundation + CryptoKit only, no I/O
│                 Defines the PriceProvider and LogRemote protocols
├─ Ledger         Runtime: storage (GRDB) · op application · snapshot reads · change stream ·
│                 valuation · sync engine
├─ Pricing        PriceProvider implementations (ECB). The only place with network code
└─ CloudKitSync   (phase 2) CloudKit implementation of LogRemote

Cowry.app         AppKit (macOS). The composition root
(iOS app)         UIKit, in phase 2 alongside sync. Shares CowryKit as is
```

```
              Cowry.app
         ┌───────┼────────┐
       Ledger  Pricing  CloudKitSync
         └───────┼────────┘
             LedgerCore
```

Adapters (`Pricing`, `CloudKitSync`) depend only on `LedgerCore`. The app creates them and injects them into `Ledger`.

### 2.2 How the separation is enforced

- **GRDB stays hidden.** `Ledger` uses `internal import GRDB` (SE-0409); a GRDB type in the public API is a compile error.
- **Only the runtime builds validated values.** Initializers of validated domain values such as `Entry` and `Account` are `package`. The app can only build drafts such as `EntryDraft`.
- **The runtime knows nothing about networks.** Prices and remote storage come in through `LedgerCore` protocols.
- **The UI–runtime boundary has exactly three parts.**
  - Commands: each authors one op.
  - Snapshot reads: consistent data as of one moment.
  - The change stream: what changed.
  - A future CLI or iOS UI is another thin adapter over the same API.

### 2.3 Runtime API

```swift
public final class Ledger: Sendable {
    public init(at url: URL, device: DeviceID, primaryCurrency: String = "KRW") throws

    // Commands: each authors and applies one op
    public func post(_ draft: EntryDraft) async throws -> Entry
    public func amend(_ entry: Entry, to draft: EntryDraft) async throws -> Entry
    public func void(_ entry: Entry) async throws
    public func openAccount(name: String, type: AccountType, parent: Account.ID?,
                            openedOn: LocalDate) async throws -> Account
    public func closeAccount(_ account: Account, on date: LocalDate) async throws
    // … one per op kind (§6.2)

    // Reads and changes
    public func snapshot() -> LedgerSnapshot
    public func changes() -> AsyncStream<LedgerChange>
    public func verify() throws -> VerificationReport

    // Outside world
    public func refreshPrices(using providers: [any PriceProvider]) async throws   // planned
    public func sync(with remote: any LogRemote) async throws -> SyncReport        // phase 2
}

/// A read-only view fixed at one moment. Every method is synchronous and fast
/// (called from a list's data source).
public struct LedgerSnapshot: Sendable {
    public func journal(_ filter: JournalFilter) throws -> JournalIndex          // sorted keys
    public func journalKeys(of ids: some Collection<Entry.ID>,
                            matching filter: JournalFilter) throws -> [JournalKey]
    public func entries(_ ids: [Entry.ID]) throws -> [Entry]                     // batch read
    public func register(of accounts: Set<Account.ID>) throws -> Register        // with running balances
    public func accounts() throws -> AccountTree
    public func balances(asOf date: LocalDate?) throws -> [Account.ID: Holdings]
    public func history(of target: some CustomStringConvertible) throws -> [Op]   // edit history
    public func valuation(of holdings: Holdings, in target: Commodity.ID,
                          asOf date: LocalDate) throws -> Valuation               // planned
    public func diagnostics() throws -> [Diagnostic]                             // planned
}

/// Published whenever ops are applied, by a local command or by sync.
public struct LedgerChange: Sendable {
    public let snapshot: LedgerSnapshot
    public let entries: Set<Entry.ID>        // may have been inserted, updated or removed
    public let accounts: Set<Account.ID>
    public let commodities: Set<Commodity.ID>
    public let prices, balanceAssertions, settings, conflicts: Bool
}

public typealias Holdings = [Commodity.ID: Int64]
```

### 2.4 Concurrency

- **The runtime object.** `Ledger` is a `Sendable` class wrapping a GRDB `DatabasePool`, not an actor.
- **Writes.** Every write goes through GRDB's single writer, so local commands and sync application are serialized for free.
- **Reads.** Reads run on WAL snapshots, using GRDB's `DatabaseSnapshotPool`.
  - In WAL mode reads never wait for writes, so small synchronous batch reads on the main thread are fine.
  - Holding an old snapshot blocks WAL checkpoints; the UI drops the previous snapshot as soon as a new change arrives.
- **Change stream.** Change events come out of op application: the applier knows exactly which rows it touched, so the changed-ID sets are exact and free. Re-running queries and diffing them (GRDB `ValueObservation`) isn't used for lists.
- **LedgerCore** creates no threads and no async runtime.

## 3. Domain model

### 3.1 Value types and normalization

| Value | Representation | Rule |
|---|---|---|
| Amount | `Int64` in minor units | Interpreted with `commodity.scale`. No floating point |
| Date | `LocalDate` (`YYYY-MM-DD`) | Never `Foundation.Date`. Ledger dates are calendar days and must not shift when the time zone changes |
| ID | UUID | UUIDv7 for ordinary entities; deterministic UUIDv5 for ISO currencies and system accounts. Lowercase text in the database, 16 bytes in digests |
| String | NFC, trimmed, empty becomes `nil` | Hangul can arrive as NFC or NFD. Swift `==` treats them as equal; SQLite compares bytes |
| Rate | Decimal text → `Decimal` | Canonicalized when authored (no exponent, no trailing zeros) and stored as that text |
| Authoring time | HLC | §6.1 |

Normalization happens once, where a draft becomes a validated value.

### 3.2 Sign convention

- Debits are positive, credits negative. Every entry sums to zero per commodity.
- Liability, equity and income accounts have negative normal balances; signs flip only for display.

### 3.3 Entities

| Entity | Fields | Notes |
|---|---|---|
| Commodity | code, kind (currency · security · crypto · other), **scale**, name, quote, feed | `scale` never changes. `quote` is the commodity its prices are quoted in (AAPL → USD) |
| Account | **type** (asset · liability · equity · income · expense), parent, name, role, opened_on, closed_on, archived, deleted, merged_into, sort_order, note | `type` never changes; children share their parent's type. The full path isn't stored. `deleted` is a tombstone |
| Entry | date, created_at, payee, memo, postings (≥ 2) | A posting is (account, commodity, amount) |
| Price | base, quote, date, rate | Only prices entered by hand |
| BalanceAssertion | account, commodity, date, amount | "The balance at the start of `date`" |
| Setting | key, value | `primary_commodity`, … |

**System accounts.** `Equity:Conversion` (role = conversion) and `Equity:Opening Balances` (role = opening_balance) are created with deterministic UUIDv5s when the ledger is created.

**Ops that create deterministic IDs are idempotent.** If an entity with that ID already exists with the same content, nothing happens, so two devices can each create KRW or the system accounts without conflict.

### 3.4 Ledger = library = file = zone

- The ledger is a library managed by the app, not a document people open and save ([ux.md §3.1](ux.md)).
- One library is one SQLite file and, from phase 2, one CloudKit custom zone.
- Phase 1 has a single library.
- Multiple ledgers (personal, business, …) come later as library switching, and ledgers are fully independent.

## 4. Multiple currencies and valuation

### 4.1 Principles

- **Record in the original commodity; value at query time.** The primary currency is just a setting. Changing it changes no data, only what's displayed.
- **The rate actually applied and the public rate are different things.**
  - The rate actually applied to a transaction is a fact, recorded in the entry.
  - Public rates are only used to value holdings.
  - Example: if a $50 purchase is charged ₩68,650 to a card, ₩68,650 is the truth whatever the public rate was that day.

### 4.2 Conversion account (trading accounts)

For entries mixing commodities, the runtime generates postings to the system account `Equity:Conversion`.

```
2026-09-20  Apple Store
  Expenses:Shopping          50.00 USD
  Liabilities:Visa        -68,650 KRW
  Equity:Conversion         -50.00 USD   ← generated
  Equity:Conversion        68,650 KRW    ← generated
```

**Generation rule.** Find every commodity whose sum in the draft isn't zero.
- If there is **exactly one**, the draft is wrong (unbalanced).
- If there are **two or more**, add a `(Conversion, c, −Σc)` posting for each such commodity `c`.
- This happens when a draft becomes an `Entry`; the op stores the final postings (principle 4).

**Display.** Conversion postings are hidden. The UI shows the implied rate instead, e.g. "$50 · ₩68,650 (₩1,373/$)".

**Why this approach**
- **The invariant is one integer comparison.** `SUM(amount) = 0` per commodity. No rounding-tolerance rules.
- **Converted balance sheets always balance.** Each commodity sums to zero, so valuing every account at the same rates sums to zero.
- **FX gains fall out.** `Equity:Conversion` valued in the primary currency is the cumulative FX gain or loss (for securities, the unrealized gain).
  - Example: convert ₩1,000,000 to $730, then the rate moves to ₩1,500.
  - Conversion holds −730 USD + 1,000,000 KRW, which values at −₩95,000: a ₩95,000 credit.
  - That is a ₩95,000 gain.

### 4.3 Prices

| Kind | Stored in | Synced |
|---|---|---|
| Entered by hand | op (`set_price`) → `price` table | Yes |
| Fetched from outside | `market_price` local cache | No (each device fetches its own) |

**Exchange rates.** ECB reference rates:
- Free, no API key.
- Include KRW, with history since 1999.
- All currencies arrive together, so nothing reveals which ones someone holds.

**Securities.** Phase 1 supports manual prices only; `PriceProvider` plugins come later. Settings state plainly that quoting a security reveals the holding to the provider.

**Crypto.** Later.

**Refresh.** On launch or daily. History is backfilled from the date a commodity was first held.

```swift
public protocol PriceProvider: Sendable {
    var id: String { get }
    func quotes(for pairs: [PricePair], in range: ClosedRange<LocalDate>) async throws -> [PriceQuote]
}
```

### 4.4 Valuation

```
value(holdings, target, asOf):
  for each commodity c:
    c == target                 → as is
    otherwise find a path c → … → target (both directions, depth ≤ 3, e.g. AAPL → USD → EUR → KRW)
      each hop uses the latest rate on or before asOf; manual prices win over the cache
    no path                     → report as unvalued; never convert to 0
  result: total, unvalued holdings, oldest rate date used
```

- Arithmetic uses `Decimal`; rounding happens only for display.
- The UI shows the **rate date** alongside converted values. Amounts without a rate stay in their commodity, marked "No rate".
- **Valuation dates (proposal).**
  - Balances and net worth use rates as of the query date.
  - Period income and expense reports use each posting's own date.
  - Within one entry every commodity sums to zero, so valuing a whole entry at one date keeps reports balanced.
- **Net worth over time.** Daily cumulative balances per commodity times the rate series, carrying the last known rate forward.

### 4.5 Out of scope (phase 3)

Per-lot cost basis (capital gains tax). Total unrealized gain already falls out of §4.2.

## 5. Storage (SQLite)

### 5.1 The op table: source of truth

```sql
CREATE TABLE op (
  id           TEXT PRIMARY KEY,   -- UUID (also in body)
  status       TEXT NOT NULL,      -- main | pending   (device-local metadata)
  seq          INTEGER UNIQUE,     -- position in main; NULL while pending
  local_order  INTEGER,            -- authoring order of pending ops
  body         BLOB NOT NULL,      -- bytes exactly as the authoring device wrote them; never re-encoded
  resolution   BLOB,               -- main only: merge resolution (§6.3); NULL if none was needed
  kind         TEXT NOT NULL,      -- extracted from body (for indexing)
  target       TEXT NOT NULL,      -- extracted from body: target entity (history, 3-way merge)
  version      INTEGER NOT NULL,   -- extracted from body
  prev_hash    BLOB,               -- main only
  state_digest BLOB,               -- main only: digest of the state after this op
  hash         BLOB                -- main only
);
CREATE INDEX op_by_target ON op(target, seq);
```

### 5.2 Materialized tables: local, always rebuildable

- Every row has a `rev` column: the id of the op that last changed it. Op ids survive rebase unchanged, which makes `rev` the basis for detecting concurrent edits.
- Ops are applied strictly in order and structural invariants always hold, so unlike synced tables these can have foreign keys.

```sql
CREATE TABLE commodity (
  id TEXT PRIMARY KEY, code TEXT NOT NULL, kind TEXT NOT NULL, scale INTEGER NOT NULL,
  name TEXT, quote_id TEXT REFERENCES commodity(id), feed TEXT,
  archived INTEGER NOT NULL DEFAULT 0, rev TEXT NOT NULL
);

CREATE TABLE account (
  id TEXT PRIMARY KEY, parent_id TEXT REFERENCES account(id),
  name TEXT NOT NULL, type TEXT NOT NULL, role TEXT,
  opened_on TEXT NOT NULL, closed_on TEXT,
  archived INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0,
  merged_into TEXT REFERENCES account(id),
  sort_order INTEGER NOT NULL DEFAULT 0, note TEXT, rev TEXT NOT NULL
);

CREATE TABLE entry (
  id TEXT PRIMARY KEY, date TEXT NOT NULL, created_at TEXT NOT NULL,
  payee TEXT, memo TEXT, rev TEXT NOT NULL
);
CREATE INDEX entry_by_date ON entry(date, created_at, id);

-- account_id is as authored; resolved_account_id follows merged_into.
-- Balances and registers use resolved_account_id. Merging accounts rewrites only the
-- resolved column, so entry content (and its rev and digest) stays the same.
CREATE TABLE posting (
  entry_id            TEXT NOT NULL REFERENCES entry(id) ON DELETE CASCADE,
  idx                 INTEGER NOT NULL,
  date                TEXT NOT NULL,                 -- copy of entry.date (for indexing)
  account_id          TEXT NOT NULL REFERENCES account(id),
  resolved_account_id TEXT NOT NULL REFERENCES account(id),
  commodity_id        TEXT NOT NULL REFERENCES commodity(id),
  amount              INTEGER NOT NULL,
  PRIMARY KEY (entry_id, idx)
) WITHOUT ROWID;
CREATE INDEX posting_by_account ON posting(resolved_account_id, date, commodity_id, amount);

CREATE TABLE price (
  id TEXT PRIMARY KEY, base_id TEXT NOT NULL, quote_id TEXT NOT NULL,
  date TEXT NOT NULL, rate TEXT NOT NULL, rev TEXT NOT NULL
);

CREATE TABLE balance_assertion (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL, commodity_id TEXT NOT NULL,
  date TEXT NOT NULL, amount INTEGER NOT NULL, rev TEXT NOT NULL
);

CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL, rev TEXT NOT NULL);

CREATE TABLE conflict_dismissal (op_id TEXT PRIMARY KEY);   -- result of dismiss_conflict ops
```

### 5.3 Local auxiliary tables

```sql
-- Before-images of rows an op changed. Used to roll back pending ops and for undo.
CREATE TABLE op_undo (op_id TEXT NOT NULL, step INTEGER NOT NULL, tbl TEXT NOT NULL,
                      row_key TEXT NOT NULL, before BLOB,   -- NULL = row was created
                      PRIMARY KEY (op_id, step));

-- Cache of fetched prices
CREATE TABLE market_price (
  base_id TEXT NOT NULL, quote_id TEXT NOT NULL, date TEXT NOT NULL,
  rate TEXT NOT NULL, provider TEXT NOT NULL, fetched_at TEXT NOT NULL,
  PRIMARY KEY (base_id, quote_id, date, provider)
) WITHOUT ROWID;

-- hlc, head_seq, head_hash, state_digest, …
CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB NOT NULL);
```

### 5.4 Migrations

- Only the op table and the op body format need careful migrations.
- When a materialized table's schema changes, drop the tables and rebuild them by replaying the log. Materialized tables get no migration code.
- `PRAGMA user_version` tells whether the schema changed.

### 5.5 Queries and performance

- **Scale.** Twenty entries a day for ten years is about 73,000 entries and 180,000 postings. Performance targets assume a generous 100,000 entries (§8.2).
- **Account balances.** `SUM` over the covering index `posting_by_account`; milliseconds.
- **Held in memory.** The account tree, commodities, the sorted key array of each open list, and running sums of each open register (§8.3).
- **Monthly balance snapshot table.** Only if measurements show a need.
- **Full replay.** Target: a few seconds for 100,000 ops, to be measured.

### 5.6 File location (proposal)

- The database lives in an App Group container from phase 1.
- Then a CLI bundled in the app (phase 3) needs no file move.
- CLI signing and entitlement details are verified in phase 3.

## 6. Ops

### 6.1 Envelope

```json
{"v":1,"id":"…","device":"…","at":"1759032753123-0003","kind":"post_entry","payload":{…}}
```

- **Encoded once.** Only the authoring device encodes; storage and transport keep the bytes as they are.
- **Never re-encoded.** Decoding ignores unknown fields, but the bytes are kept and never re-encoded.
- **`v` is the op format version.** An unknown `v` in main can't be applied from that point on, so the app asks to be updated (§7.4).
- **`at` is a hybrid logical clock (HLC)** reading: physical milliseconds plus a counter.
  - Whenever a device receives main ops, it raises its HLC to at least the largest value seen.
  - So an edit made after seeing another device's change always reads later, even with a wrong wall clock.
  - Merge policies decide "the later edit" by this value, breaking ties by device id.
  - It never orders main.
  - For `post_entry`, `at` becomes `entry.created_at`.

### 6.2 Kinds and authoring validation

Op kinds map one-to-one to runtime commands. **Authoring validation** is applied when an op is created locally. Merging never refuses an op for these rules; §6.3 resolves conflicts instead.

Ops with a `base_rev` must match the record's current `rev` when authored. A mismatch means the copy being edited is stale (e.g. the same entry edited in two windows): authoring is refused and the UI reloads so the person can edit again. As a result, 3-way merges only happen during rebase.

| kind | payload | Authoring validation |
|---|---|---|
| `create_commodity` | id, code, kind, scale, name, quote, feed | The id must not exist (a deterministic id with identical content is a no-op) |
| `update_commodity` | id, base_rev, name, quote, feed | code and scale can't change |
| `archive_commodity` | id, base_rev | |
| `open_account` | id, parent, name, type, opened_on, role | Parent exists with the same type; no sibling with the same name |
| `update_account` | id, base_rev, name, parent, sort_order, note | type can't change; no cycles; no duplicate sibling names |
| `close_account` | id, base_rev, date | No postings after the close date |
| `reopen_account` | id, base_rev | |
| `archive_account` | id, base_rev | |
| `merge_accounts` | from, into | Same type; from ≠ into; into isn't a descendant of from |
| `delete_account` | id, base_rev | No postings, child accounts or balance assertions |
| `post_entry` | id, date, payee, memo, postings | At least two postings; each commodity sums to zero; accounts exist, aren't archived and are open on the date |
| `amend_entry` | id, base_rev, date, payee, memo, postings | Same as `post_entry`; replaces the whole entry |
| `void_entry` | id, base_rev | Removed from the ledger; kept in the log |
| `set_price` | id, base, quote, date, rate | Commodities exist; rate > 0 |
| `remove_price` | id, base_rev | |
| `assert_balance` | id, account, commodity, date, amount | Account and commodity exist |
| `remove_assertion` | id, base_rev | |
| `set_setting` | key, value | Checked per key |
| `dismiss_conflict` | op_id | Hides an acknowledged conflict-log item on every device |

**Structural invariants that always hold**
- **Per-entry balance per commodity.** Checked within a single op, so merging can't break it.
- **Resolvable references.** Accounts are never physically deleted; `deleted` is a tombstone. Merged accounts redirect via `merged_into`, which every reference follows before resolving.
- **An acyclic account tree.**
- **Immutable fields.** type and scale never change.

### 6.3 Merge policy (proposal)

When a pending op collides with the new main state during rebase, these defaults resolve it. The outcome is recorded in the op's `resolution` and goes into main.

| Situation | Default resolution | Conflict log |
|---|---|---|
| The same entry edited concurrently | **3-way merge by field group.** Groups: {date}, {payee}, {memo}, {postings}. A group changed on one side takes that change; a group changed on both sides takes the side with the later `at`. **Postings are always chosen as a whole, never mixed posting by posting.** | Yes (highlighted if postings lost) |
| Edit vs. void | Later `at` wins. A later edit brings the entry back | Yes |
| Void vs. void | No-op | No |
| Account or commodity attributes edited concurrently | 3-way merge by field; fields changed on both sides take the later `at` | Yes |
| Entry posting to a closed account | Apply the entry; the period violation appears as a diagnostic | Diagnostic |
| Entry posting to an archived account | Apply the entry and unarchive the account | Yes |
| Entry posting to a deleted account | Apply the entry and restore the account | Yes |
| Deleting an account that meanwhile got postings | Archive instead of delete | Yes |
| Entry posting to a merged account | Redirect via `merged_into` | No |
| Moving an account creates a cycle | That move becomes a no-op | Yes |
| Duplicate sibling account names | Keep both; the later one gets " (2)" | Yes (with a merge action) |
| Two manual prices for the same (base, quote, date) | Keep both; lookups use the later `at` | No |
| Settings changed concurrently | Later `at` wins | No |

**The base of a 3-way merge.** An op's `base_rev` marks the base.
- Fold the target entity's ops up to `base_rev` to reconstruct the base (using the `op_by_target` index).
- "What the other side changed", and when, comes from the main ops applied to the same target after the base.

**Why resolutions are recorded (principle 4).**
- Replay never re-evaluates policies: it applies the effective payload from `resolution` when present, otherwise the body's payload.
- So changing policy code in an app update never changes what past replays produce.

```json
{"rule":"field_merge","effective":{…payload applied…},"lost":["postings"],"against":["<op id>"]}
```

### 6.4 Diagnostics

States that are structurally sound but that people should know about. They never block input.

```swift
public enum Diagnostic: Sendable, Hashable {
    case balanceAssertionFailed(BalanceAssertion.ID, expected: Amount, actual: Amount)
    case postingOutsideOpenPeriod(Entry.ID, Account.ID)
    case closedAccountHasBalance(Account.ID, Holdings)
    case missingPrice(Commodity.ID, target: Commodity.ID, asOf: LocalDate)
    case stalePrice(Commodity.ID, target: Commodity.ID, lastDate: LocalDate)
}
```

## 7. Sync

### 7.1 Model

- **main.** A single linear op log on the remote, ordered by conditional append (CAS).
- **Local.** A copy of main with pending ops layered on top. What the screen shows is main plus the resolved pending ops.
- **Local-only mode (phase 1).** The device orders ops itself: each command immediately gets a seq, state digest and hash and goes into main.
- **Turning sync on (phase 2).** Existing local main ops go back to pending and are rebased onto the remote main. If the remote is empty they're uploaded as is.

### 7.2 Hash chain and state digest

```
hash(n)         = SHA-256( hash(n−1) ‖ state_digest(n) ‖ enc(body(n)) ‖ enc(resolution(n)?) )   hash(0) = 0x00 × 32
state_digest(n) = digest of the state after applying ops 1…n
```

`body` and `resolution` have variable length, so they're wrapped in `enc` (length-prefixed, below) to keep the boundary between them unambiguous.

- **The hash chain** detects corruption and tampering in storage or transit, and forks in history.
  - It hashes the **stored bytes**. Nothing is re-encoded, so no canonical serialization is needed.
- **The state digest** detects devices whose replays of the same ops produce different states, whether from interpretation differences between app versions or from bugs.
  - It's computed by a function we define, not by serializing to a format.

```
enc(UUID)      = 16 bytes
enc(LocalDate) = "YYYY-MM-DD", 10 bytes
enc(Int64)     = 8 bytes big-endian
enc(String)    = UInt32 big-endian length ‖ UTF-8 (NFC)
enc(Bytes)     = UInt32 big-endian length ‖ bytes
enc(x?)        = 0x00  |  0x01 ‖ enc(x)
enc(Bool)      = 0x00  |  0x01

record_digest(entry) = SHA-256( enc("cowry.entry.v1")
                              ‖ enc(id) ‖ enc(date) ‖ enc(created_at) ‖ enc(payee?) ‖ enc(memo?) ‖ enc(rev)
                              ‖ enc(Int64(postings.count))
                              ‖ for each posting: enc(account) ‖ enc(commodity) ‖ enc(amount) )
… other record kinds follow the same pattern, with tags separating domains

state_digest = Σ record_digest(r)  mod 2²⁵⁶      r = every domain record (caches excluded)
```

- **Incremental.** Applying an op only needs `− old record digest + new record digest`: O(1).
  - A sum of hashes is weak against deliberate manipulation; the hash chain covers that.
- **Frozen.** Test vectors pin the digest functions. A change means adding a new function at an op-version boundary.

### 7.3 Transport

```swift
public protocol LogRemote: Sendable {
    /// Streams ops with seq > after, in order, and keeps streaming new ones.
    func ops(after seq: Int64) -> AsyncThrowingStream<[RemoteOp], Error>

    /// Appends only if the remote head is still expectedHead.
    func append(_ ops: [RemoteOp], expectedHead: Int64) async throws -> AppendResult
}

public struct RemoteOp: Sendable {
    public let seq: Int64
    public let body: Data
    public let resolution: Data?
    public let prevHash: Data
    public let stateDigest: Data
    public let hash: Data
}

public enum AppendResult: Sendable { case appended, headMoved }
```

| Implementation | Purpose |
|---|---|
| `InMemoryRemote` | Tests: simulates several devices in one process |
| `CloudKitRemote` | Phase 2 (§7.6) |

### 7.4 Algorithm

```
1. fetch     Receive ops with seq > local head; use only the contiguous run
             Verify prev_hash and hash; raise the HLC
2. roll back Undo pending ops in reverse (op_undo)
3. apply     Apply main ops in order, using resolution when present; compare each state_digest
4. rebase    Reapply pending ops in authoring order on the new state
               no collision → apply as is
               collision    → resolve with §6.3 and create a resolution
             No op is ever refused
5. push      Give pending ops seq = head+1…, resolution, state_digest and hash; append(expectedHead: head)
               on headMoved, go back to 1
```

| Situation | Handling |
|---|---|
| Hash mismatch | Stop syncing and report remote corruption |
| Digest mismatch | Replay locally from scratch and check again. If it still differs, report replay divergence (a bug) and stop syncing |
| Unknown op version | Stop applying main and ask for an app update. Local input keeps accumulating as pending |
| `headMoved` | Repeat from fetch |
| Offline | Pending ops accumulate; the screen stays valid |

### 7.5 Conflict log

- **What it shows.** Main ops with a `resolution` whose situation is marked for the conflict log in §6.3.
  - Resolutions live in main, so every device sees the same log.
  - What lost is still in the log and can be restored at any time.
- **Each item shows** which rule applied, what lost, and both versions.
- **Actions**
  - **Restore this version** creates a new `amend_entry` with the losing content — an ordinary op.
  - **Merge** creates a `merge_accounts` for duplicate names.
  - **Dismiss** creates a `dismiss_conflict`.
- **Emphasis.** Items where postings (amounts) lost get a sidebar badge. Memo or payee losses are only logged.
- **Nothing is refused.** No op ever waits on a person to resolve it.

### 7.6 CloudKit mapping (phase 2)

- **Zone.** One custom zone per ledger.
- **Records.** Record type `Op`, named `op-<seq, zero-padded to 12 digits>`.
  - Fields: `body` and `resolution` (both `encryptedValues`), `prev_hash`, `state_digest`, `hash`.
- **CAS.** Saving a record whose name already exists is rejected by the server, which we read as `headMoved`. Several ops go up together with an atomic zone save.
- **Verify first.** A small prototype checks that CKSyncEngine can express these semantics.
  - If not, drop down to `CKModifyRecordsOperation` and `CKFetchRecordZoneChangesOperation`.
  - Only append and fetch are needed, so the fallback is cheap.
- **Accepted downsides**
  - Signing out of iCloud or running out of storage stops sync; the UI shows sync status.
  - Production schemas can't drop fields. Op records barely change, though, and domain changes go through the body's `v`.

## 8. UI (macOS, AppKit)

### 8.1 Structure

Screens, flows and presentation rules follow [ux.md](ux.md). This section covers implementation only.

- **Window structure.** One `NSSplitViewController` with three panes ([ux.md §3.2](ux.md)):
  - Sidebar: an `NSOutlineView` of arbitrary depth
  - List: a view-based `NSTableView`
  - Inspector
- **Mixing in SwiftUI.** Static screens such as Settings may use SwiftUI via `NSHostingController`. Lists and editing are AppKit.
- **Undo.** `UndoManager` registers actions that author the inverse op, so undoing is itself an op in the log ([ux.md §4.6](ux.md)).

### 8.2 Performance targets (proposal)

With 100,000 entries:
- **Scrolling** never stutters.
- **Filtering and search** show results within 100 ms of typing.
- **Edits** appear within one frame, keeping selection and scroll position.

Phase 1 includes a synthetic data generator for measuring these.

### 8.3 Virtualized lists

```
LedgerSnapshot.journal(filter)  →  JournalIndex: sorted keys [(date, created_at, id)]
                                   100,000 × ~40 bytes ≈ 4 MB
numberOfRows                    =  index.count
visible rows ± margin           →  snapshot.entries(ids) synchronous batch read → controller cache
LedgerChange                    →  locate changed IDs by binary search on sort keys → index diff
                                   insertRows / removeRows / reloadData(forRowIndexes:)
```

- **No full reloads.** `NSTableViewDiffableDataSource` isn't used either: it would diff all 100,000 identifiers on every change. Updates come straight from the IDs a change event names.
- **Filtering and search.** SQL builds a new sorted key array. On a change event, only the changed IDs are re-checked with `WHERE id IN (…) AND <filter>`.
- **Search.** At this scale a `LIKE` scan is fast enough; queries are NFC-normalized too. The FTS5 trigram tokenizer can't match fewer than three characters, which rules it out for two-syllable Korean words like "커피" (coffee).
- **Register running balances.** Per account, an array of (sort key, amount) with running sums in memory. A backdated entry recomputes only from that point on.
- **Row height** is fixed (`usesAutomaticRowHeights = false`).

## 9. Testing

- **LedgerCore unit tests.** Authoring validation, conversion postings, amounts, normalization (NFC, …) and merge policies, case by case.
- **Digest test vectors.** Fixed inputs and expected hashes; any change to the spec fails immediately.
- **Property tests** over random op sequences:
  - Structural invariants hold at every point.
  - The digest from a full replay equals the incremental digest.
  - Applying and then rolling back pending ops returns to the main digest.
  - Replaying main with recorded resolutions reproduces the digests from when they were resolved.
- **Multi-device simulation** with `InMemoryRemote` and N fake devices going on- and offline at random while emitting ops:
  - Main always satisfies the structural invariants.
  - Every op eventually reaches main; none are lost.
  - Once everything is quiet, every device has the same digest.
- **List performance benchmarks.** Filtering, search and change application over 100,000 synthetic entries.

The whole runtime is testable without a UI.

## 10. Phases

**Phase 1 — local-only macOS app**
- `LedgerCore`: types, ops, authoring validation, merge policy, conversion postings, digests.
- `Ledger`
  - Op log, materialization, op_undo.
  - Snapshot reads and the change stream.
  - Valuation, diagnostics, local sequencing.
  - Sync engine and `InMemoryRemote` (for tests).
- `Pricing`: ECB and manual prices.
- The AppKit app (§8) and a synthetic data generator.

**Phase 2 — sync and iOS**
- A CKSyncEngine CAS prototype, then `CloudKitSync`.
- iOS app (UIKit). The list virtualization of §8.3 carries over to `UICollectionView`.
- Conflict log and sync status UI.
- Joining an existing local ledger to sync (§7.1).

**Phase 3 — extensions**
- **CLI.**
  - Bundled in the app, using the App Group container.
  - Detects outside changes with `PRAGMA data_version`.
  - Refuses to open a database with a newer schema version.
- **Investments.** Per-lot cost basis; security price provider plugins.
- **Merkle checkpoints.** Year/month/day tree snapshots, for bootstrapping new devices, viewing the ledger as of any point in time, and caching totals keyed by node hash.
- **Log compaction.** Archive old ops in batches.
- **Export and import.** beancount export; integration with external import tools.

## 11. Rejected alternatives

| Alternative | Why rejected |
|---|---|
| Rust core + C FFI | With an Apple-only target, it only adds an FFI boundary, multi-target builds and cross-language debugging |
| CLI server (daemon) + in-memory date index | Two sources of truth; impossible on iOS; SQLite indexes suffice at this scale |
| SwiftData / Core Data | Weak aggregate queries; no control over the model or merging |
| SwiftUI lists | Performance problems with large lists, and exploring the whole ledger is the core experience |
| Document-based app (open and save `.cowry` files) | Makes ownership visible, but most people have one ledger, and it fits CloudKit sync and iOS poorly. The library offers Show in Finder and Export Backup instead |
| State replication + LWW (SQLiteData, …) | Cross-record invariants break after merges; no history; nowhere to record resolutions |
| Mandatory user resolution of merge conflicts (refusing ops) | Input stays out of the ledger until someone deals with it, and most conflicts have a natural resolution |
| git-style per-device branches + merge | A clean merge isn't a valid merge; merge commits diverge |
| A Merkle state tree as the sync backbone | Overlaps with what the linear log already gives; write amplification; poor fit for CKSyncEngine. Used only for checkpoints |
| beancount-style `@price` balancing | Needs rounding-tolerance rules |
| The SQLite file in iCloud Drive | WAL files sync separately and corrupt the database |
| A file-based log in iCloud Drive | No CAS, so no linear log |
| Our own server | Operations and authentication burden, and responsibility for other people's financial data |

## 12. Open questions

1. **Foreign-currency purchases.** [ux.md §4.3](ux.md) proposes entering both the original amount and the charged amount. What's left is whether the model should carry an "estimated" flag for charges not yet known ([ux.md §11](ux.md)).
2. **Minimum OS.** Provisionally macOS 15 / iOS 18. CKSyncEngine's floor is macOS 14 / iOS 17.
3. **Balances of closed accounts.** Block a nonzero balance on close at authoring time, or report it as a diagnostic (current proposal)?
4. **Valuation date for period reports.** Each posting's own date (current proposal) or the query date?
5. **Duplicate account names.** Keep both with " (2)" (current proposal) or merge automatically?
6. **Securities price provider.** Which to support first (phase 3)?
