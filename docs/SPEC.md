# Anchor design spec (repo Acidgorgon/anchor)

Goal: a session-locked DataStore library for Roblox that is a drop-in upgrade of
loleris' ProfileStore 1.0.3 (reference copy: `reference/ProfileStore-1.0.3.luau`),
with: never-lose-data safety, lower CPU/memory, smaller saves, fewer DataStore
calls, dupe-proof trades and receipts, an easier API, and a clean seam to Ripple
(state replication lib, wraps `profile.Data` in place).

**Rule zero: data safety beats every other goal.** Any optimisation that adds a
data-loss path is rejected. When in doubt, save the plain stock format.

## 1. Compatibility contract (must hold at all times)

Real games roll out new versions while old servers are still running. Old
servers run stock ProfileStore. Both will touch the same keys.

1. **Envelope** is the stock one, field for field:
   ```
   { Data = {...},
     MetaData = { ProfileCreateTime, SessionLoadCount, ActiveSession = {PlaceId, JobId, sessionGuid} | nil,
                  ForceLoadSession = {PlaceId, JobId} | nil, LastUpdate, MetaTags = {} , Anchor = {...ours} },
     RobloxMetaData = {}, UserIds = {},
     GlobalUpdates = { lastIndex, { {index, data}, ... } } }
   ```
   Our own bookkeeping lives ONLY in `MetaData.Anchor` (stock keeps unknown MetaData
   fields because it edits MetaData in place). Never add top-level keys.
2. **Lock protocol identical to stock**: same UpdateAsync transform rules
   (ActiveSession / ForceLoadSession / SessionLoadCount / LastUpdate), same
   constants and defaults (AUTO_SAVE_PERIOD 300, LOAD_REPEAT_PERIOD 10,
   FIRST_LOAD_REPEAT 5, SESSION_STEAL 40, ASSUME_DEAD 630,
   START_SESSION_TIMEOUT 120, critical-state constants, MAX_MESSAGE_QUEUE 1000),
   same MessagingService topic `"PS_" .. sessionGuid` and payload
   `{LoadCount = n, EndSession = true|nil}`. A stock server and our server must
   be able to hand a profile back and forth with no data loss.
3. **Reads every legacy format**: ProfileStore 1.x, ProfileService
   (GlobalUpdates entries `{id, version, locked, data}`; ProfileStore already
   reads these, copy its handling), and our Compact format (below).
4. **Format modes** (`Format` option):
   * `"Compat"` (DEFAULT): `Data` is a plain table, byte-for-byte what stock
     would write. Safe with old servers alive.
   * `"Compact"` (opt-in, only after every old server is gone): `Data =
     { AnchorBlob = <buffer from Codec> }`. To stop a stock server from ever
     loading (and silently wiping) a Compact profile, Compact saves POISON the
     stock counter: `MetaData.SessionLoadCount = "Anchor"` (non-numeric string) and
     the real count moves to `MetaData.Anchor.LoadCount`. Every stock session-start
     path ends in `SessionLoadCount + 1` inside the UpdateAsync transform, which
     then throws, so the write is discarded and stock retries until its 120 s
     timeout and returns nil (game kicks the player). Stock may still write a
     `ForceLoadSession` request (harmless, we honour it). This MUST be proven by
     a test that runs real stock ProfileStore against a Compact profile.
   * Switching Compact -> Compat later is allowed: the writer un-poisons.
5. Readers always accept both modes regardless of the configured writer mode.

## 2. Codec (`src/Codec.luau`)

Schemaless binary encoding of JSON-acceptable Luau values to a `buffer`.
* Header: magic `"ANC"`, version byte, flags. Unknown version -> error, never guess.
* Types: nil-in-array is invalid (same as DataStore), bool, integers as zigzag
  varints when `math.floor(x) == x and |x| < 2^53`, otherwise f64 (exact).
  Reject NaN and +-inf (DataStore rejects them too; report the path).
* Strings: length-prefixed; a string table interns every map key AND every
  repeated string value (index varint) so 670 cards x 10 keys costs 10 key strings.
* Tables: array (1..n contiguous, no holes) or map (string keys; number keys
  allowed only the way Roblox JSON allows: DataStore converts mixed/numeric keys
  badly, so follow stock warnings: reject mixed tables and sparse arrays with a
  clear path in the error). Empty table encodes as empty array (JSON `[]`
  semantics; decoding returns `{}`).
* `buffer` values pass through (DataStore supports them).
* Cycles -> error with path. Depth limit 200.
* API: `encode(value) -> buffer`, `decode(buf) -> value`,
  `decodeInto(buf, target)` (clears target and refills it in place, keeps table
  identity of the root), `validate(value) -> (ok, path?, reason?)`,
  `equal(a, b) -> boolean` (deep).
* Every Compact save re-decodes and deep-compares before writing (default on,
  option `VerifyWrites`). On mismatch: write Compat for this save, fire OnError.
* Speed: write with a growable buffer and `buffer.write*`, no string concat;
  read with cursor; native-codegen friendly (`--!native`, `--!optimize 2`).
* Roblox base64s buffers in JSON and zstd-compresses them (`zbase64`); we cannot
  run that here, so benches report raw buffer bytes, base64 size, and a zstd
  estimate via python's zstandard if available. Mark Studio-only facts as such.

## 3. Core (`src/init.luau` + `src/Core.luau`)

Port stock behaviour first (lock, load, autosave, release, messages, BindToClose,
critical state, Mock, GetAsync, VersionQuery, RemoveAsync, MessageAsync,
SetAsync), then apply only these changes:
* `LastSavedData`: keep the last saved snapshot as a Codec blob (5-10x smaller
  than a deep-copied table) and decode lazily on first read via `__index`.
  Exposed field name and semantics unchanged.
* Clean-save skip: at autosave, encode Data (needed anyway in Compact mode);
  if bytes equal the last saved blob AND the last successful write was less
  than `LockRefresh` (default 300 s, must stay well under ASSUME_DEAD 630) ago
  AND no messages/tx/user-id/metadata changes are pending, skip the DataStore
  call. Optional hook `IsDirty(profile) -> boolean` (Ripple can supply one) to
  skip the encode as well.
* Pre-save validation: Codec.validate on Data before UpdateAsync; on failure do
  not call the DataStore (Roblox would reject it), fire `OnError` with the path,
  keep the profile active and retry next cycle. Release saves still retry.
* Size guard: warn and fire OnError above 3.5 MB serialized estimate.
* O(1) autosave list removal (index map), no `table.find`.
* Profile.Data table identity is stable for the whole session.

## 4. Safety features

* **Receipts**: `store:ProcessReceipt(receiptInfo, grant)`: dedup ledger of the
  last 100 PurchaseIds in `MetaData.Anchor.Receipts`; apply grant once; force a
  save; return `PurchaseGranted` only after a save that contains the PurchaseId
  succeeded; otherwise `NotProcessedYet`.
* **Trades** `Store.Trade(profileA, profileB, fn, opts)` (both active on this
  server; may be different stores). Dupe-proof, loss-proof:
  1. Run `fn(draftA, draftB)` on deep copies in a pcall. Error -> abort, no change.
  2. Diff drafts vs live -> patches PA, PB (ops: `Inc(path, delta)` for numbers,
     `Set(path, value)`, `Remove(path)`).
  3. Apply PA to live A and add `A.MetaData.Anchor.Tx[id] = {peer = {store, key}, patch = PB, t = os.time()}`
     in the same tick. Force-save A (the durable intent). If A's session is lost
     before this save succeeds: trade never happened (B untouched). Return false.
  4. Only after A's intent is saved: apply PB to live B and set
     `B.MetaData.Anchor.Applied[id] = os.time()`; force-save B.
     If B is no longer active here: deliver PB via MessageAsync to B's key as
     `{AnchorTx = id, Patch = PB}`; the lib's built-in message handler applies it
     once (dedup by Applied) on whichever server owns B next.
  5. When B's save with Applied[id] succeeds (or the message is accepted), drop
     A's Tx record on A's next save.
  6. Recovery: whenever a profile loads with Tx records that are not cleared,
     re-send them as messages (B dedups). Applied entries are pruned after 30
     days, max 500 entries.
  * Patches are applied through `opts.Live = {liveA, liveB}` when given (Ripple
    proxies, so changes replicate) else to `profile.Data`. Path writes are plain
    `t[k1][k2] = v`, `t[k] += n`, `t[k] = nil`.
  * Number deltas are increments so redo on newer data never clobbers progress.
* Gifts to offline players: `store:Gift(key, patchOrFn)` = step 4 message path.

## 5. Easy API (`src/init.luau`)

```lua
local Anchor = require(path.To.Lib)
local Data = Anchor.new("Main", Template, { Format = "Compat" })
Data:Bind()                         -- PlayerAdded/Removing/BindToClose, AddUserId,
                                    -- Reconcile, kicks on failure, key "Player_<id>"
local profile = Data:Get(player)    -- nil if not loaded
local profile = Data:Await(player)  -- yields until loaded or player leaves
Data.Loaded:Connect(function(player, profile) end)
Data:Update(player, function(data) data.Cash += 10 end)
Anchor.Trade(Data:Get(a), Data:Get(b), function(da, db) ... end)
```
`Bind` options: `Key = function(player) -> string` (FM uses `"PLAYER_" .. id`),
`OnLoaded`, `KickMessage`. Also exports the full stock API
(`Anchor.New(name, template)` returning an object with stock methods) so a game
can swap the module with no code changes.

## 6. Tests and benches (`tests/`, `bench/`)

Plain Luau 0.700 VM host (copied from blink-plus benchmark/harness/host) with a
Roblox mock using VIRTUAL TIME so 10 minutes of autosaves run in milliseconds.
Multi-server simulation: N "servers" each with own JobId/PlaceId and their own
fresh `require` of the library, sharing one backing DataStore + MessagingService.
DataStore mock: UpdateAsync/GetAsync/GetVersionAsync/ListVersionsAsync/RemoveAsync,
values deep-copied through a JSON round trip (Roblox semantics; buffers stored as
base64 objects), KeyInfo with Version/CreatedTime/UpdatedTime/GetUserIds/
GetMetadata, latency, error injection, throttling, server crash (kill a server:
its threads stop, no BindToClose), counters (calls by type, bytes written).
Required suites: stock ProfileStore passes its behaviours on the mock (proves the
mock); ours passes the same; mixed stock+ours handoff in both directions with no
loss; Compact profile + stock server never loses data; migration from saved
ProfileStore and ProfileService blobs; trades with crash at every step (no dupe,
no loss); receipts; codec fuzz.
Benches vs stock: load CPU, save CPU, heap alloc, resident memory per profile,
saved bytes (JSON length / buffer+base64), DataStore calls per hour for idle and
active players. FM-shaped data (~670 owned cards x ~10 fields) plus small data.

## 7. Ripple seam (agreed with the Ripple thread, 2026-11-16)

* `Ripple.X.new(player, profile.Data)` wraps the plain table in place; Anchor
  never replaces `profile.Data` and never puts metatables in it.
* Trade patches applied through Ripple proxies: assigning a table stores THAT
  table as the plain child, so the patch walker must assign a fresh deep copy.
  Ripple type-checks writes against its schema and errors on a bad write: the
  walker must pcall each proxy write and, on error, write the same value into the
  plain table instead (data stays correct and saved; only replication of that
  field is missed) and fire OnError. Never leave a patch half applied.
* `Ripple.isDirty(state)` / `Ripple.clearDirty(state)`: per-root flag for tracked
  writes. Writes that bypass the proxy don't set it, so the IsDirty hook may only
  skip encoding when the game routes every write through Ripple; default stays
  byte compare.
