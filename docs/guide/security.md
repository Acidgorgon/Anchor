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
crashes or a save fails mid-trade. Traded items sit in escrow in both saves until one stored decision
says commit or abort, and each side applies that decision exactly once.

**Exactly-once receipts.** `Data:ProcessReceipt` records each `PurchaseId` in the profile together with
the grant, and returns `PurchaseGranted` only after a save containing both has landed. Unconfirmed ids are
never dropped from the ledger, so a retried or duplicated receipt is never granted twice.

**Exactly-once gifts.** Each `Data:Gift` call is applied once, in the same save that removes it from the
player's message queue.

**Values a DataStore can't hold.** Trades, gifts and receipts refuse changes that contain values a
DataStore can't store (functions, `Instance`s, NaN, ...) before anything is applied
(`false, "Invalid"` or `NotProcessedYet`). Trades that would push a save over 4 MB are refused
(`"TooBig"`).

**Compact saves can't be wiped by old code.** Stock ProfileStore servers and admin tools can't load or
overwrite a [Compact](/guide/save-formats#why-old-servers-can-t-wipe-a-compact-profile) profile.

**Dev options can't run live.** `Mock`, `Reset`, `PlayAs`, `View` and `NoSave` (in code or as
attributes) are ignored on live servers with a warning, unless you pass `AllowDevOptionsLive = true` in
code. See [Studio test options](/guide/studio-testing#studio-only-guard).

## What Anchor can't protect against

- **Trusting the client.** If a RemoteEvent lets a client say "give me 1000 coins" or "trade my Sword for
  their Dragon" without checks, Anchor will save that faithfully. Validate every request on the server:
  ownership, amounts, cooldowns, and that both players agreed to a trade.
- **Checks outside the trade function.** Check balances and item ownership **inside** the function you pass
  to `Anchor.Trade`. It runs on the latest data while both profiles are locked for trading.
- **Unsaved progress on a crash.** A server crash loses changes since the last save (autosave runs every
  5 minutes), exactly like ProfileStore. Trades and receipts save immediately; for other valuable
  changes, call `profile:SaveAsync()`.
- **Very old receipts.** Once a purchase's save is confirmed, the ledger keeps only the newest 100
  confirmed `PurchaseId`s per player. Roblox stops retrying a receipt once it is granted, so this only
  matters if Roblox redelivers a granted receipt after 100 newer purchases by the same player.
- **Calling `Gift` twice.** Each call is a new gift. Guard your own retries.
- **Your own deletes.** `RemoveAsync`, `SetAsync` overwrites and `Reset` with `AllowDevOptionsLive = true`
  do what they say.
- **Roblox outages.** If DataStores are down, saves fail and retry, profiles fail to load and players are
  kicked rather than given empty data. Listen to `Anchor.OnCriticalToggle` to warn players or pause
  trading.

## Known limits

- **Direct writes during a trade.** A trade commits over about one save (around a second).
  `Data:Update` waits for it, and a write that lands while the trade function runs makes the trade return
  `"Error"`, but a direct write to `profile.Data` after that, while the escrow saves are in flight, is not
  held back. Route gameplay writes through `Data:Update`, or check `profile:IsTrading()`.
- **Catch-all message handlers on old servers.** During a mixed rollout, a profile loaded on a stock
  ProfileStore server hands Anchor's gift (`AnchorTx`) and `Send` (`AnchorTopic`) messages to your old
  `MessageHandler`. If that handler calls `processed()` on every message, the gift or message is dropped.
  Only mark messages you recognise as processed. Escrowed trades are not affected: their records live in
  `MetaData.Anchor`, which stock keeps, and they resolve when the player next loads on an Anchor server.
- **Benchmarks can't see Roblox's C++.** Anchor's numbers come from a Luau VM outside Roblox. They can't
  include Roblox's C++ JSON encode/decode or its buffer compression, so the real cost and size on Roblox
  may differ. See [Benchmarks](/benchmarks).

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
