# Migrating from ProfileStore

Anchor runs the ProfileStore 1.0.3 API unchanged. Swap the module and your game keeps working.

## 1. Swap the require

```lua
-- Before
local ProfileStore = require(game.ServerScriptService.ProfileStore)

-- After
local ProfileStore = require(game.ServerScriptService.Anchor)
```

Everything below works exactly as before:

```lua
local PlayerStore = ProfileStore.New("PlayerStore", Template)

local profile = PlayerStore:StartSessionAsync(`Player_{player.UserId}`, {
	Cancel = function() return player.Parent ~= Players end,
})
profile:AddUserId(player.UserId)
profile:Reconcile()
profile.OnSessionEnd:Connect(function() player:Kick() end)
```

- **Same store names and keys.** Anchor uses the same DataStore and the same key you pass. Nothing is
  copied or renamed, and there is no migration step.
- **Same stored format.** By default Anchor writes exactly what ProfileStore writes
  ([Compat](/guide/save-formats)).
- **Same lock protocol, constants and messages**: autosave every 300 s, session steal after 40 s,
  `ASSUME_DEAD` 630 s, the `PS_` MessagingService topic, `MessageAsync` / `MessageHandler`,
  `GetAsync`, `VersionQuery`, `RemoveAsync`, `SetConstant`, `.Mock`, `OnError`, `OnOverwrite`,
  `OnCriticalToggle`, `IsClosing`, `IsCriticalState`, `DataStoreState`.
- **Older saves load as is**, including profiles written by ProfileService.

One addition you may want: `profile:SaveAsync()` saves now and yields until the write lands, returning
`true` or `false` (stock `profile:Save()` doesn't tell you).

## 2. Roll out while old servers are running

You don't need to shut down. Old ProfileStore servers and new Anchor servers can own the same profile one
after the other: when a player moves from an old server to a new one (or back), the normal session
hand-off happens and nothing is lost. This is tested in both directions.

Keep two things in mind until the last old server is gone:

- **Stay on `Format = "Compat"`** (the default). [Compact](/guide/save-formats#when-to-switch) is for
  after.
- **Old message handlers see Anchor's messages.** Gifts and trade deliveries travel through the
  profile's message queue as tables with an `AnchorTx` field (and `Send` uses `AnchorTopic`). If your old
  `MessageHandler` calls `processed()` on messages it doesn't recognise, an old server could drop one.
  Only mark messages you handled as processed.

## 3. Simplify (optional)

When you're ready, the player-loading boilerplate becomes one call:

```lua
local Anchor = require(game.ServerScriptService.Anchor)

local Data = Anchor.new("PlayerStore", Template) -- same store name
Data:Bind()                                      -- same "Player_<UserId>" keys
```

`Bind` does `StartSessionAsync`, `AddUserId`, `Reconcile`, the kick on failure or session loss, and
`EndSession` on leave. If your keys use another prefix, keep them:

```lua
local Data = Anchor.new("PlayerStore", Template, { KeyPrefix = "PLAYER_" })
-- or, for any other key shape:
Data:Bind({ Key = function(player) return "Save_" .. player.UserId end })
```

## Coming from a DataService wrapper

Many games wrap ProfileStore in their own `DataService` with helpers like `Get`, `Update`, mock mode,
reset-on-join and "play as user". Those map onto built-in Anchor features:

| Your wrapper | Anchor |
|---|---|
| `DataService:Get(player)` / wait for data | `Data:Get(player)` / `Data:Await(player)` |
| `DataService:Update(player, fn)` | `Data:Update(player, fn)` |
| Loaded / leaving events | `Data.Loaded`, `Data.Leaving` |
| `UseMock` | `{ Mock = true }` or a `Mock` attribute ([Studio test options](/guide/studio-testing)) |
| `ResetData` | `{ Reset = true }`, or `Data:Reset(player)` |
| `OverriddenUserId` | `{ PlayAs = userId }` (plays and saves) or `{ View = userId }` (read-only) |
| Custom key format | `{ KeyPrefix = "PLAYER_" }` or `Bind({ Key = fn })` |
| Cross-server "give item" | `Data:Gift(userId, fn)` or `Data:Send(userId, topic, payload)` |
| `ProcessReceipt` boilerplate | `Data:HandleReceipts({ [productId] = fn })` |

All dev options are ignored on live servers, so a forgotten `Reset` can't wipe real players.
