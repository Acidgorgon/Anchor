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

## How Anchor prevents it

`Anchor.Trade` never relies on two saves landing together:

1. Your function runs on **copies** of both players' data. If it errors or returns `false`, nothing
   changes.
2. Anchor turns the changes into two small patches. Alice's patch is applied, and Bob's patch is written
   **into Alice's save** as a pending record. Anchor saves Alice right away.
3. Only once that save has landed does Bob get his patch, tagged with the trade's id, and Anchor saves
   Bob. Alice keeps the pending record until Bob's save shows the trade id as applied.
4. If anything crashes in between, the record in Alice's save is picked up again the next time her
   profile loads. Bob's save remembers which trade ids it has applied, so a replay is applied **at most
   once**.

So either Alice's save never recorded the trade (nothing happened to either player), or it did and Bob is
guaranteed to receive his side exactly once. If Bob left mid-trade, his side is sent through his save's
message queue and applied on whichever server loads him next.

Numbers are patched as increments (`+40`, not `= 140`), so a replay onto newer data keeps any coins Bob
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
else
	warn("Trade failed:", reason)
end
```

Both profiles must be loaded on this server. They can come from different stores. Only one trade runs per
profile at a time; a second trade on the same player waits (up to 30 seconds) and then runs on the fresh
data.

| Result | Meaning | Data changed? |
|---|---|---|
| `true` | Done. Both sides have their new data (or Bob gets his on his next load if he left). | Yes |
| `false, "Cancelled"` | Your function returned `false`. | No |
| `false, "Error", message` | Your function errored. | No |
| `false, "Invalid", message` | Bad arguments, the same profile twice, a read-only (`View`/`NoSave`) profile, or values a DataStore can't store. | No |
| `false, "Inactive"` | A player isn't loaded on this server (left, or not loaded yet). | No |
| `false, "Busy"` | Another trade on one of them didn't finish within the timeout. | No |
| `false, "SaveFailed"` | Alice's save kept failing (DataStore outage). The trade was undone. | No |
| `false, "SessionLost"` | Alice's session ended mid-trade and no save could be confirmed. Usually nothing changed; if the trade did reach her save, it completes on her next load. | Never duplicated or lost |

Options (fourth argument):

```lua
Anchor.Trade(a, b, fn, {
	Timeout = 30,           -- seconds to wait for another trade on the same player
	Live = { liveA, liveB }, -- Ripple states to write through (default: the UseRipple states)
})
```

::: tip
The function gets copies, so it can't yield its way into a race: check balances **inside** the function,
not before calling `Trade`.
:::

If only one side's data changes, Anchor applies it as a normal edit (saved with the next autosave), since
there is nothing to keep in sync.

### While a trade is committing

A trade takes about one save (typically around a second). During that window `profile:IsTrading()` is
`true`, and `Data:Update(player, fn)` waits for the trade to finish so its change lands on the post-trade
data. Direct writes to `profile.Data` are **not** held back, so route gameplay writes through
`Data:Update` (or check `IsTrading()`).

### Trades that need a human

Bob's save forgets applied trade ids after 90 days (or beyond 2000 of them). If Alice's pending record is
older than that window and Bob's save shows neither the trade applied nor queued, Anchor can't tell
whether Bob already got it, so it does **not** resend it (that could duplicate). It keeps the record,
fires `Anchor.OnError` with `NEEDS MANUAL REVIEW`, and lists it in `Data:PendingTrades(profile)`:

```lua
for _, rec in Data:PendingTrades(profile) do
	print(rec.Id, rec.Store, rec.Key, rec.Status, rec.Created) -- Status: "NeedsReview", "Waiting", ...
end
```

In normal play this never happens: it takes a pending record to sit unresolved for months.

## Gifts

`Data:Gift` changes a player's data whether they're on this server, another server, or offline. It goes
through the save's message queue and is applied exactly once by whichever server owns the profile, now or
at their next join.

```lua
Data:Gift(userId, function(data)
	data.Coins += 50
end)

-- With an Id, the same gift is applied at most once per player (for example a login reward).
-- The player's save remembers applied ids for 90 days (up to 2000 of them).
Data:Gift(userId, function(data) data.Coins += 500 end, { Id = "launch_2026" })
```

The function runs on a copy of the latest data Anchor can see, and its changes are sent as a patch, so
progress the player makes in the meantime is kept. It returns `true`, or `false` with a reason
(`"Cancelled"`, `"Error"`, `"Invalid"`, or `"Failed"` if the message couldn't be sent).

The target is a UserId (key `KeyPrefix .. UserId`) or a full key string.

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
- A grant that errors or returns `false` changes nothing and returns `NotProcessedYet`.
- The player must be in this server with their data loaded, otherwise `NotProcessedYet` (Roblox
  delivers it again when they join).
- `HandleReceipts` replaces `MarketplaceService.ProcessReceipt`, so use it for one store only.
