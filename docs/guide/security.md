# Security

Anchor is a server-only saving library. It keeps saves consistent and stops the classic dupes; it does not
decide what a client is allowed to ask for. That part is your game code.

## What Anchor protects

**Server-authoritative data.** Anchor only runs on the server and never sends data to clients. Clients see
data only through what you replicate yourself (for example [Ripple](/guide/ripple), which validates every
write against its schema).

**One server per profile.** The ProfileStore session lock means a profile is loaded and written by one
server at a time, so two servers can't each spend the same coins.

**Dupe-proof trades.** [`Anchor.Trade`](/guide/trades) can't duplicate or delete items when a server
crashes or a save fails mid-trade. Each side of a trade is applied at most once, and a trade that can't
be confirmed is undone or completed later, never both.

**Exactly-once receipts.** `Data:ProcessReceipt` records each `PurchaseId` in the profile (the last 100)
together with the grant, and returns `PurchaseGranted` only after a save containing both has landed. A
retried or duplicated receipt is never granted twice.

**Exactly-once gifts.** `Data:Gift(userId, fn, { Id = "..." })` is applied at most once per Id.

**Values a DataStore can't hold.** Trades, gifts and receipts refuse changes that contain values a
DataStore can't store (functions, `Instance`s, NaN, ...) before anything is applied
(`false, "Invalid"` or `NotProcessedYet`).

**Dev options can't run live.** `Mock`, `Reset`, `PlayAs`, `View` and `NoSave` (in code or as
attributes) are ignored on live servers with a warning, unless you pass `AllowDevOptionsLive = true` in
code. See [Studio test options](/guide/studio-testing#studio-only-guard).

## What Anchor can't protect against

- **Trusting the client.** If a RemoteEvent lets a client say "give me 1000 coins" or "trade my Sword for
  their Dragon" without checks, Anchor will save that faithfully. Validate every request on the server:
  ownership, amounts, cooldowns, and that both players agreed to a trade.
- **Checks outside the trade function.** Check balances and item ownership **inside** the function you pass
  to `Anchor.Trade`. It runs on the latest data while both profiles are locked for trading.
- **Writes during a trade.** `Data:Update` waits for a running trade, but direct writes to `profile.Data`
  in that window (about one save) are not held back.
- **Unsaved progress on a crash.** A server crash loses changes since the last save (autosave runs every
  5 minutes), exactly like ProfileStore. Trades and receipts save immediately; for other valuable
  changes, call `profile:SaveAsync()`.
- **Receipt ledger size.** The ledger keeps the last 100 `PurchaseId`s per player. A receipt retried after
  more than 100 newer purchases by the same player would not be recognised.
- **Your own deletes.** `RemoveAsync`, `SetAsync` overwrites and `Reset` with `AllowDevOptionsLive = true`
  do what they say.
- **Roblox outages.** If DataStores are down, saves fail and retry, profiles fail to load and players are
  kicked rather than given empty data. Listen to `Anchor.OnCriticalToggle` to warn players or pause
  trading.

## Checklist

```lua
-- 1. Validate requests from clients before touching data.
TradeRemote.OnServerEvent:Connect(function(player, otherUserId, offer)
	if typeof(otherUserId) ~= "number" or typeof(offer) ~= "table" then return end
	local other = Players:GetPlayerByUserId(otherUserId)
	if not other or not tradeAccepted(player, other, offer) then return end

	-- 2. Check ownership inside the trade function.
	Anchor.Trade(Data:Get(player), Data:Get(other), function(a, b)
		if not a.Items[offer.ItemId] then return false end
		b.Items[offer.ItemId], a.Items[offer.ItemId] = a.Items[offer.ItemId], nil
	end)
end)

-- 3. Know when DataStores are struggling.
Anchor.OnCriticalToggle:Connect(function(isCritical)
	tradingEnabled = not isCritical
end)
```
