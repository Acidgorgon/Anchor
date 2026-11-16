# API reference

Everything Anchor exposes. Anchor's additions to the ProfileStore API are marked **Anchor**; everything
else behaves like ProfileStore 1.0.3.

```lua
local Anchor = require(game.ServerScriptService.Anchor)
```

[[toc]]

## Module

### Anchor.new

```lua
Anchor.new(name: string, template: table?, options: Options?) -> Store
```

Creates a store for the DataStore `name` (1–50 characters). `template` is the starting data for new
profiles and what `Reconcile` fills missing keys from. `Anchor.New` is the same function (the stock
name); both accept the [options](#options) and pick up [dev-option attributes](#dev-options).

```lua
local Data = Anchor.new("Main", { Coins = 0, Items = {} }, { KeyPrefix = "PLAYER_" })
```

### Options

Third argument of `Anchor.new`. Every field is optional.

| Option | Type | Default | What it does |
|---|---|---|---|
| `Format` | `"Compat" \| "Compact"` | `"Compat"` | How `Data` is written. See [Save formats](/guide/save-formats). |
| `VerifyWrites` | `boolean` | `true` | Compact only: decode and compare each blob before writing it; on a mismatch that save is written Compat and `OnError` fires. |
| `KeyPrefix` | `string` | `"Player_"` | Key used by `Bind`, `Send`, `Gift` and receipts: `KeyPrefix .. UserId`. Must be non-empty. |
| `LastSavedData` | `boolean` | `true` | `false` skips the copy of the data kept at load; `profile.LastSavedData` is then always `nil`. Saves memory and CPU for games that never read it. |
| `LockRefresh` | `number` (seconds) | `300` | An unchanged autosave may be skipped only while the last write is younger than `min(LockRefresh, 0.75 × ASSUME_DEAD − AUTO_SAVE_PERIOD)`. At default constants no autosave is ever skipped. |
| `IsDirty` | `(profile) -> boolean` | none | Return `false` to say the data is unchanged, so a skippable autosave doesn't need to compare it. See [Ripple](/guide/ripple#skipping-clean-saves-with-ripple-s-dirty-flag-advanced). |
| `ClearDirty` | `(profile) -> ()` | none | Called when a save writes the data, to reset your dirty flag. |
| `Mock` | `boolean` | `false` | Dev option (Studio only). |
| `Reset` | `boolean` | `false` | Dev option (Studio only). |
| `PlayAs` | `number` (UserId) | none | Dev option (Studio only). |
| `View` | `number` (UserId) | none | Dev option (Studio only). |
| `NoSave` | `boolean` | `false` | Dev option (Studio only). |
| `AllowDevOptionsLive` | `boolean` | `false` | Honour dev options on live servers too. Code only. |

```lua
local Data = Anchor.new("Main", Template, {
	Format = "Compact",
	LastSavedData = false,
})
```

### Dev options

`Mock`, `Reset`, `PlayAs`, `View` and `NoSave` are explained in
[Studio test options](/guide/studio-testing). They can also be set as attributes on the Anchor
ModuleScript; an option passed in code wins. On a live server they are ignored (one warning per store)
unless `AllowDevOptionsLive = true`.

```lua
local Data = Anchor.new("Main", Template, { PlayAs = 123456, Mock = true })
```

### Anchor.Trade <Badge type="tip" text="Anchor" />

```lua
Anchor.Trade(
	profileA: Profile,
	profileB: Profile,
	fn: (dataA: table, dataB: table) -> false?,
	options: { Timeout: number?, Live: { any }? }?
) -> (ok: boolean, reason: string?, message: string?)
```

Changes two loaded profiles so that the result can never be duplicated or lost. `fn` edits copies;
return `false` to cancel. Reasons: `"Cancelled"`, `"Error"`, `"Invalid"`, `"Inactive"`, `"Busy"`,
`"SaveFailed"`, `"SessionLost"` (see [Trades](/guide/trades#anchor-trade)). Yields for about one save.

- `Timeout` (default `30`): seconds to wait while another trade on either profile finishes.
- `Live`: `{ stateA, stateB }` to write through instead of the `UseRipple` states.

```lua
local ok, reason = Anchor.Trade(Data:Get(a), Data:Get(b), function(da, db)
	if da.Coins < 100 then return false end
	da.Coins -= 100
	db.Coins += 100
end)
```

Only available when the `Trade` child module is present.

### Anchor.SetConstant

```lua
Anchor.SetConstant(name: string, value: number)
```

Changes a ProfileStore constant: `AUTO_SAVE_PERIOD`, `LOAD_REPEAT_PERIOD`, `FIRST_LOAD_REPEAT`,
`SESSION_STEAL`, `ASSUME_DEAD`, `START_SESSION_TIMEOUT`, `CRITICAL_STATE_ERROR_COUNT`,
`CRITICAL_STATE_ERROR_EXPIRE`, `CRITICAL_STATE_EXPIRE`, `MAX_MESSAGE_QUEUE`.

```lua
Anchor.SetConstant("AUTO_SAVE_PERIOD", 60)
```

### Anchor.OnError

```lua
Anchor.OnError: Signal<(message: string, storeName: string, key: string)>
```

DataStore errors (as in ProfileStore), plus Anchor's own reports: a rejected save with the path of the
bad value, a Compact verify mismatch, a Ripple write that fell back to the plain table, a trade that
needs manual review.

```lua
Anchor.OnError:Connect(function(message, storeName, key)
	warn("Data problem", storeName, key, message)
end)
```

### Anchor.OnOverwrite

```lua
Anchor.OnOverwrite: Signal<(storeName: string, key: string)>
```

A corrupted value was found and overwritten (stock behaviour).

```lua
Anchor.OnOverwrite:Connect(function(storeName, key) warn("Overwrote", storeName, key) end)
```

### Anchor.OnCriticalToggle

```lua
Anchor.OnCriticalToggle: Signal<(isCritical: boolean)>
```

Fires when many DataStore errors happen in a short time, and again when that ends.

```lua
Anchor.OnCriticalToggle:Connect(function(isCritical) tradingEnabled = not isCritical end)
```

### Anchor.IsClosing, IsCriticalState, DataStoreState

```lua
Anchor.IsClosing: boolean        -- the server is shutting down
Anchor.IsCriticalState: boolean  -- see OnCriticalToggle
Anchor.DataStoreState: "NotReady" | "NoInternet" | "NoAccess" | "Access"
```

```lua
if Anchor.DataStoreState ~= "Access" then print("Data won't be saved in this session") end
```

## Store: easy API <Badge type="tip" text="Anchor" />

### Store:Bind

```lua
Store:Bind(options: {
	Key: ((player: Player) -> string)?,
	OnLoaded: ((player: Player, profile: Profile) -> ())?,
	KickMessage: string?,  -- default "Your data could not be loaded. Please rejoin."
	LoadTimeout: number?,  -- seconds, default 120
}?) -> Store
```

Loads every player who joins (and players already in game), with `AddUserId` and `Reconcile`; kicks if
loading fails or times out, or if the session is taken by another server; ends the session when they leave.
Call once per store.

```lua
Data:Bind({ KickMessage = "Couldn't load your save, please rejoin." })
```

### Store:Get

```lua
Store:Get(player: Player) -> Profile?
```

The player's profile, or `nil` if it isn't loaded. Requires `Bind`.

```lua
local profile = Data:Get(player)
if profile then print(profile.Data.Coins) end
```

### Store:Await

```lua
Store:Await(player: Player) -> Profile?  -- yields
```

Waits until the player's profile is loaded. Returns `nil` if the player leaves first (or the server
closes before it loads). Requires `Bind`.

```lua
local profile = Data:Await(player)
```

### Store:Update

```lua
Store:Update(player: Player, fn: (data: table) -> ()) -> boolean
```

Runs `fn` on the player's data and returns `true`, or returns `false` if the player isn't loaded. `fn`
receives the Ripple state when `UseRipple` is set, otherwise `profile.Data`. If a trade on the player is
committing, waits for it first.

```lua
Data:Update(player, function(data) data.Coins += 10 end)
```

### Store.Loaded

```lua
Store.Loaded: Signal<(player: Player, profile: Profile)>
```

Fires when `Bind` has loaded a player.

```lua
Data.Loaded:Connect(function(player, profile) print(player.Name, "loaded") end)
```

### Store.Leaving

```lua
Store.Leaving: Signal<(player: Player, profile: Profile)>
```

Fires when a player leaves, before the session ends. Changes made here are saved.

```lua
Data.Leaving:Connect(function(player, profile) profile.Data.LastSeen = os.time() end)
```

### Store:UseRipple

```lua
Store:UseRipple(fn: (player: Player, profile: Profile) -> any) -> Store
```

Called once per loaded player (and for players already loaded). The returned state is what `Update`
hands to its function, and what trades, gifts, receipts and `Reset` write through.

```lua
Data:UseRipple(function(player, profile) return Ripple.Club.new(player, profile.Data) end)
```

### Store:Send

```lua
Store:Send(target: number | string, topic: string, payload: any) -> boolean  -- yields
```

Sends a message to a player's save: a UserId (key `KeyPrefix .. UserId`) or a full key. It is handled on
whichever server has the player loaded, or when they next join. Returns whether the message was stored.

```lua
Data:Send(friendUserId, "FriendRequest", { From = player.UserId })
```

### Store:OnMessage

```lua
Store:OnMessage(topic: string, handler: (player: Player, payload: any) -> false?) -> Store
```

Handles `Send` messages with this topic for players loaded by `Bind`. Return `false` to keep the message
for later; otherwise it is removed from the save. Register handlers before players join: a message that
arrives with no handler stays in the save until a later session handles it.

```lua
Data:OnMessage("FriendRequest", function(player, payload)
	Data:Update(player, function(data) table.insert(data.Requests, payload.From) end)
end)
```

### Store:Reset

```lua
Store:Reset(player: Player) -> boolean
```

Studio only (or `AllowDevOptionsLive`). Refills the player's data from the template in place and returns
`true`. On a live server it warns and returns `false`. Nothing is deleted: the old save stays in version
history.

```lua
Data:Reset(player)
```

### Store:Gift

```lua
Store:Gift(
	target: number | string,
	gift: ((data: table) -> false?) | Patch,
	options: { Id: string? }?
) -> (ok: boolean, reason: string?, message: string?)  -- yields
```

Changes a player's data wherever they are: on this server, another server, or offline (applied at their
next join). Applied exactly once. With `Id`, the same gift is applied at most once per player (applied ids
are remembered for 90 days, up to 2000). Reasons: `"Cancelled"`, `"Error"`, `"Invalid"`, `"Failed"`.

```lua
Data:Gift(userId, function(data) data.Coins += 500 end, { Id = "launch_2026" })
```

`gift` can also be a patch: an array of operations with a path from the data root.

| Op | Effect |
|---|---|
| `{ "Inc", path, delta }` | `t[k] = (t[k] or 0) + delta` |
| `{ "Set", path, value }` | `t[k] = value` (a copy) |
| `{ "Remove", path }` | `t[k] = nil` |
| `{ "Push", path, value }` | append `value` to an array |
| `{ "Pull", path, value }` | remove the first array item equal to `value` |

```lua
Data:Gift(userId, { { "Inc", { "Coins" }, 100 }, { "Push", { "Items" }, "Sword" } })
```

Only available when the `Trade` child module is present.

### Store:PendingTrades

```lua
Store:PendingTrades(profile: Profile) -> { {
	Id: string, Store: string, Key: string, Patch: Patch, Created: number,
	Status: "NeedsReview" | "Delivering" | "Waiting" | "Committing",
} }
```

Trade records the profile still holds as the giving side, oldest first. `"NeedsReview"` records were not
resent because a resend could duplicate; see [Trades that need a human](/guide/trades#trades-that-need-a-human).

```lua
for _, rec in Data:PendingTrades(profile) do print(rec.Id, rec.Status) end
```

### Store:ProcessReceipt

```lua
Store:ProcessReceipt(
	receiptInfo: table,
	grant: (data: table, receiptInfo: table, player: Player?) -> false?
) -> Enum.ProductPurchaseDecision  -- yields
```

Grants a developer product exactly once. Returns `PurchaseGranted` only after a save containing the grant
and its `PurchaseId` landed; otherwise `NotProcessedYet`. `grant` runs on a copy; return `false` (or error)
to refuse. The player must be loaded on this server.

```lua
MarketplaceService.ProcessReceipt = function(info)
	return Data:ProcessReceipt(info, function(data) data.Coins += 100 end)
end
```

Only available when the `Receipts` child module is present.

### Store:HandleReceipts

```lua
Store:HandleReceipts(handlers: GrantFn | { [productId: number]: GrantFn }) -> Store
```

Sets `MarketplaceService.ProcessReceipt` to call `ProcessReceipt` with your grant(s). With a table, an
unknown ProductId warns and returns `NotProcessedYet`.

```lua
Data:HandleReceipts({ [123456] = function(data) data.Coins += 100 end })
```

## Store: ProfileStore API

### Store:StartSessionAsync

```lua
Store:StartSessionAsync(key: string, params: { Steal: boolean?, Cancel: (() -> boolean)? }?) -> Profile?  -- yields
```

Loads and locks a profile. Returns `nil` if it couldn't (timeout, `Cancel`, shutdown).

```lua
local profile = Data:StartSessionAsync("Player_" .. player.UserId, {
	Cancel = function() return player.Parent ~= Players end,
})
```

### Store:MessageAsync

```lua
Store:MessageAsync(key: string, message: table) -> boolean  -- yields
```

Adds a message to a profile's queue; the owner receives it through `profile:MessageHandler`.

```lua
Data:MessageAsync("Player_123", { Type = "Gift", Coins = 50 })
```

### Store:GetAsync

```lua
Store:GetAsync(key: string, version: string?) -> Profile?  -- yields
```

Reads a profile without locking it ("view mode"). Edit it and call `:SetAsync()` to overwrite.

```lua
local view = Data:GetAsync("Player_123")
if view then print(view.Data.Coins) end
```

### Store:VersionQuery

```lua
Store:VersionQuery(key: string, sortDirection: Enum.SortDirection?, minDate: (DateTime | number)?, maxDate: (DateTime | number)?) -> VersionQuery
VersionQuery:NextAsync() -> Profile?  -- yields
```

Walks saved versions of a key (not available in mock mode).

```lua
local query = Data:VersionQuery("Player_123", Enum.SortDirection.Descending)
local previous = query:NextAsync()
```

### Store:RemoveAsync

```lua
Store:RemoveAsync(key: string) -> boolean  -- yields
```

Deletes a key (for example a GDPR request).

```lua
Data:RemoveAsync("Player_123")
```

### Store.Mock

The same methods (`StartSessionAsync`, `MessageAsync`, `GetAsync`, `VersionQuery`, `RemoveAsync`) on an
in-memory store.

```lua
local profile = Data.Mock:StartSessionAsync("Test_1")
```

## Profile

### Fields

| Field | Type | |
|---|---|---|
| `Data` | `table` | Your data. Same table for the whole session. |
| `LastSavedData` | `table?` | The data as last saved. `nil` with `LastSavedData = false`. |
| `FirstSessionTime` | `number` | Unix time the profile was created. |
| `SessionLoadCount` | `number` | How many sessions have loaded this profile. |
| `Session` | `{ PlaceId: number, JobId: string }?` | The server that owns it. |
| `RobloxMetaData` | `table` | DataStore metadata, saved with the profile. |
| `UserIds` | `{ number }` | UserIds linked to the key (GDPR). |
| `KeyInfo` | `DataStoreKeyInfo` | From the last DataStore call. |
| `ProfileStore` | `Store` | The store it came from. |
| `Key` | `string` | Its DataStore key. |

```lua
print(profile.Key, profile.SessionLoadCount, profile.Data.Coins)
```

### Signals

| Signal | Arguments | Fires |
|---|---|---|
| `OnSave` | | Right before a save. |
| `OnLastSave` | `reason: "Manual" \| "External" \| "Shutdown"` | Right before the final save. |
| `OnSessionEnd` | | The session ended (released or taken by another server). |
| `OnAfterSave` | `lastSavedData: table?` | After a save reached the DataStore. |

```lua
profile.OnSessionEnd:Connect(function() player:Kick("Data session ended") end)
```

### Methods

```lua
profile:IsActive() -> boolean         -- still owned by this server
profile:Reconcile()                   -- fill missing keys from the template
profile:EndSession()                  -- save and release
profile:AddUserId(userId: number)
profile:RemoveUserId(userId: number)
profile:MessageHandler(fn: (message: table, processed: () -> ()) -> ())
profile:Save()                        -- save soon, don't wait
profile:SetAsync()                    -- view-mode profiles only: overwrite the key
```

```lua
profile:MessageHandler(function(message, processed)
	if message.Type == "Gift" then
		profile.Data.Coins += message.Coins
		processed()
	end
end)
```

### profile:SaveAsync <Badge type="tip" text="Anchor" />

```lua
profile:SaveAsync() -> boolean  -- yields
```

Saves now and waits. `true` once a write containing the current data landed while this server still owns
the profile; `false` if it failed or the session was lost.

```lua
if profile:SaveAsync() then print("Saved") end
```

### profile:IsTrading <Badge type="tip" text="Anchor" />

```lua
profile:IsTrading() -> boolean
```

`true` while a trade involving this profile is committing (about one save).

```lua
if profile:IsTrading() then return end -- try again after the trade
```
