# Trades and anti-dupe

## Why trades dupe

With ProfileStore each player's save is its own DataStore key. A trade changes two keys, and two writes
never land at exactly the same moment:

1. Alice gives Bob a Sword. Both profiles change in memory.
2. Bob's save lands. The Sword is now in Bob's save.
3. Alice's server crashes before her save lands.
4. Alice rejoins with her old save, Sword included. **The Sword now exists twice.**

Exploiters force step 3 on purpose (crash the server, or time a trade right before a shutdown). The
reverse order loses the item instead of duplicating it.

## How Anchor prevents it: escrow, then one decision

`Anchor.Trade` is a two-phase escrow with a single commit point:

1. **Escrow.** Your function runs on **copies** of both players' data. Anchor splits each side's changes
   into what **leaves** (removed items, coins going down) and what **arrives**. In one frame it takes the
   leaving part out of both players' data and writes an escrow record into both saves: what to refund,
   and what to deliver. From this moment the traded items can't be spent twice.
2. **Save both.** Anchor saves Alice and Bob at the same time. If both escrow saves land it proposes
   *commit*, otherwise *abort*.
3. **Decide once.** The decision is written to a small key of its own (DataStore `"AnchorTx"`,
   key `tx_<id>`). The first decision written wins; anyone who comes later adopts it. This is the only
   commit point.
4. **Apply.** On *commit* each side gets its incoming items; on *abort* each side gets its refund. The
   escrow record is removed in the same frame, so a side can never get both.

If a server crashes anywhere in between, each player's save still holds the escrow record. When that
player loads again (on any server), Anchor reads the decision key and finishes the job. A side that finds
no decision proposes *abort*, which is safe: *commit* is only ever written after both escrows were saved.

Numbers move as increments (`+40`, not `= 140`), so applying a side later keeps any coins the player
earned in the meantime. Arrays are treated as bags: items are added and removed by value, never by index.

## Anchor.Trade

```lua
local ok, reason = Anchor.Trade(Data:Get(alice), Data:Get(bob), function(a, b)
	if a.Coins < 100 or b.Items.Gem == nil then
		return false -- cancel: nothing changes
	end
	a.Coins -= 100
	b.Coins += 100
	a.Items.Gem, b.Items.Gem = b.Items.Gem, nil
end)

if ok then
	-- "Trade complete"
elseif reason == "Pending" then
	-- "Trade pending": it finishes on its own
else
	warn("Trade failed:", reason)
end
```

Both profiles must be loaded on this server. They can come from different stores. Only one trade runs per
profile at a time; a second trade on the same player waits (up to 30 seconds) and then runs on the fresh
data. A trade takes about one save, usually around a second.

| Result | Meaning |
|---|---|
| `true` | Committed. Both players have their new data (a player who left mid-trade gets their side on their next load). |
| `false, "Cancelled"` | Your function returned `false`. Nothing changed. |
| `false, "Error", message` | Your function errored, or a player's data changed while it ran. Nothing changed. |
| `false, "Invalid", message` | Bad arguments, the same profile twice, a read-only (`View`/`NoSave`) profile, or values a DataStore can't store. Nothing changed. |
| `false, "Inactive"` | A player isn't loaded on this server. Nothing changed. |
| `false, "Busy"` | Another trade on one of them didn't finish within the timeout. Nothing changed. |
| `false, "TooBig"` | A save would go over the DataStore's 4 MB limit. Nothing changed. |
| `false, "SaveFailed"` | An escrow save failed (DataStore trouble). Aborted and refunded. |
| `false, "SessionLost"` | A player left or lost their session before their escrow saved. Aborted and refunded. |
| `false, "Aborted"` | Another server decided first (abort). Refunded. |
| `false, "Pending"` | The decision key couldn't be reached. The traded items stay in escrow (unspendable) and the trade commits or refunds itself as soon as the key is reachable. Show "Trade pending". |

Every abort refunds both sides. Nothing is duplicated or lost.

Options (fourth argument):

```lua
Anchor.Trade(a, b, fn, {
	Timeout = 30,            -- seconds to wait for another trade on the same player
	Live = { liveA, liveB }, -- Ripple states to write through (default: the UseRipple states)
})
```

::: tip
Check balances and ownership **inside** the function, not before calling `Trade`. The function sees the
latest data, and if something writes to either player while it runs, the trade returns `"Error"` instead
of trading on stale data.
:::

If only one side's data changes, Anchor applies it as a normal edit (saved with the next autosave), since
there is nothing to keep in sync.

### While a trade is committing

During the commit `profile:IsTrading()` is `true`, and `Data:Update(player, fn)` waits for the trade to
finish so its change lands on the post-trade data. Direct writes to `profile.Data` are **not** held back,
so route gameplay writes through `Data:Update` (or check `IsTrading()`).

### Trades that need a human

Applying a side is never forced onto data it no longer fits. If, say, an `Inc` would land on a field that
is no longer a number (because you migrated your data shape in between), Anchor keeps the escrow record,
leaves the items in escrow, fires `Anchor.OnError` with `NEEDS MANUAL REVIEW`, and lists it in
`Data:PendingTrades(profile)`:

```lua
for _, rec in Data:PendingTrades(profile) do
	print(rec.Id, rec.Role, rec.Key, rec.Status) -- Status: "NeedsReview", "Resolving" or "Waiting"
end
```

## Gifts

`Data:Gift` changes a player's data whether they're on this server, another server, or offline. It rides
the save's message queue and is applied exactly once by whichever server owns the profile, now or at their
next join: the change and the removal of the message land in the same save.

```lua
Data:Gift(userId, function(data)
	data.Coins += 50
end)
```

The function runs on a copy of the latest data Anchor can see, and its changes are sent as a patch, so
progress the player makes in the meantime is kept. A gift never brings back a parent table the player no
longer has (a sold pet doesn't come back as an empty stub) unless your template defines it.

It returns `true`, or `false` with a reason (`"Cancelled"`, `"Error"`, `"Invalid"`, or `"Failed"` if the
message couldn't be stored). The target is a UserId (key `KeyPrefix .. UserId`) or a full key string.

::: warning
Every `Gift` call sends a new gift. If your own code might call it twice for the same reward (for example
a retry after a timeout), keep your own "already given" flag in the player's data.
:::

## Receipts (developer products)

Roblox calls `ProcessReceipt` again and again until you return `PurchaseGranted`, and a rollback after
granting can give the product twice. Anchor applies each `PurchaseId` once and only returns
`PurchaseGranted` after a save containing it has landed.

One line wires up `MarketplaceService.ProcessReceipt`:

```lua
Data:HandleReceipts({
	[123456] = function(data) data.Coins += 100 end,              -- by ProductId
	[654321] = function(data, info, player) data.Gems += 10 end,
})
```

Or call it from your own handler:

```lua
MarketplaceService.ProcessReceipt = function(info)
	return Data:ProcessReceipt(info, function(data, info, player)
		if info.ProductId ~= 123456 then
			return false -- unknown product: NotProcessedYet
		end
		data.Coins += 100
	end)
end
```

- The grant runs on a copy. Its changes and the `PurchaseId` are applied together, then the profile is
  saved. If that save fails, Roblox retries later and the grant is **not** applied again.
- The ledger keeps every `PurchaseId` whose save isn't confirmed yet, plus the newest 100 confirmed ones.
- A grant that errors or returns `false` changes nothing and returns `NotProcessedYet`.
- The player must be in this server with their data loaded, otherwise `NotProcessedYet` (Roblox
  delivers it again when they join).
- `HandleReceipts` replaces `MarketplaceService.ProcessReceipt`, so use it for one store only.
