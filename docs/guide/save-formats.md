# Save formats

Anchor can write a profile two ways. It always **reads** both, whatever you pick.

```lua
local Data = Anchor.new("Main", Template)                           -- Compat (default)
local Data = Anchor.new("Main", Template, { Format = "Compact" })   -- Compact
```

## Compat (default)

The stored value is exactly what ProfileStore writes: `Data` is your plain table, and the envelope
(`MetaData`, `UserIds`, `GlobalUpdates`, ...) is field-for-field the stock one. Old ProfileStore servers
and Anchor servers can hand the same profile back and forth with nothing lost.

Anchor's own bookkeeping (pending trades, applied trade ids, the receipt ledger) lives in one extra field,
`MetaData.Anchor`. ProfileStore keeps fields it doesn't know about, so this survives a trip through an old
server. If you never trade, gift or use receipts, there is no `MetaData.Anchor` at all.

## Compact

`Data` is stored as one binary buffer made by Anchor's codec:

```lua
Data = { AnchorBlob = <buffer> }
```

The codec writes every key name once, packs small numbers into a byte or two and short decimals
(`1.99`, `73.4`) exactly. Before each Compact write Anchor decodes the buffer again and compares it with
your data (`VerifyWrites`, on by default). If they ever differ, that save is written as Compat instead and
`Anchor.OnError` fires.

### How much smaller

From the [benchmarks](/benchmarks), stored JSON size per profile:

| Data | Compat | Compact |
|---|---:|---:|
| 670 cards × 10 fields (a large card game save) | 112.1 KB | **39.1 KB** (−65%) |
| 20 small fields | 724 B | 741 B (+17 B) |

Roblox may also zstd-compress buffers inside DataStore values, which would bring the large save to about
26 KB. That is an estimate: how Roblox compresses buffers is not something we can measure outside Roblox.

Small saves don't shrink (the buffer wrapper costs a few bytes), so Compact is for big collections.

### Why old servers can't wipe a Compact profile

A ProfileStore server that loaded `{ AnchorBlob = <buffer> }` would see an empty-looking profile and could
save over it. Anchor makes that impossible: a Compact save also sets `MetaData.SessionLoadCount` to the
string `"Anchor"` and keeps the real count in `MetaData.Anchor.LoadCount`.

Every way ProfileStore starts a session runs `SessionLoadCount + 1` inside its `UpdateAsync`. On a string
that errors, the DataStore write is thrown away, and ProfileStore keeps retrying until its 120-second
timeout, then gives up. The player is kicked by your old code; their save is untouched. This is covered by
a test that runs the real ProfileStore 1.0.3 against a Compact profile, including `Steal = true` and a
crashed Anchor owner.

Two things old servers *can* still do with a Compact profile:

- `MessageAsync` to it works; the message is delivered when an Anchor server loads the profile.
- `GetAsync` returns a view whose `Data` is the raw `{ AnchorBlob = ... }`, not your table.

## When to switch

1. Ship Anchor with the default **Compat**. Old and new servers can run side by side.
2. Wait until **every** server runs Anchor (shut down old servers, or wait for them to drain).
3. Switch to `Format = "Compact"`. Each profile converts on its next save.

Going back is safe too: set `Format = "Compat"` (or remove it) and each profile is written plain again on
its next save, with the real `SessionLoadCount` restored, so ProfileStore can load it.

::: warning
Only switch to Compact once no ProfileStore server is left. Players who land on an old server would fail
to load and be kicked (their data stays safe).
:::

## What a DataStore can't store

Both formats store what Roblox stores. If a save is rejected (for example a function or an `Instance`
inside your data), Anchor reports it through `Anchor.OnError` like ProfileStore does, and adds the path of
the first bad value, such as `Data.Inventory[3]`. The profile stays loaded and the next save tries again.

In Compact mode, data the codec can't encode but Roblox would accept (mixed tables, sparse arrays) is
saved in the plain Compat form for that save, with a warning.
