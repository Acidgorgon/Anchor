# Getting started

Anchor saves player data with ProfileStore's session lock, so a player's data is only ever loaded on one
server at a time. You give it a template, call `Bind`, and read or change data whenever you like.

## Install

Anchor is one ModuleScript named `Anchor` with a few child modules (`Core`, `Codec`, `Envelope`, `Patch`,
`Signal`, `Trade`, `Receipts`). It only runs on the server.

::: code-group

```text [Studio]
ServerScriptService
└─ Anchor            ← the src/ folder as a ModuleScript (init.luau)
   ├─ Codec
   ├─ Core
   ├─ Envelope
   ├─ Patch
   ├─ Receipts       (optional: receipts)
   ├─ Signal
   └─ Trade          (optional: trades and gifts)
```

```json [default.project.json (Rojo)]
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": {
      "Anchor": { "$path": "Packages/anchor/src" }
    }
  }
}
```

:::

- **Where:** `ServerScriptService` is the natural home. `ReplicatedStorage` works too if that is where you
  keep shared packages, but only ever `require` Anchor from server scripts.
- **Wally:** a Wally package is coming. Until then, copy `src/` from the
  [repository](https://github.com/Acidgorgon/anchor).
- **Trade and Receipts are optional.** Anchor installs them automatically when they are children of the
  module. Delete them and `Anchor.Trade`, `Data:Gift` and `Data:ProcessReceipt` simply don't exist.

## Load and save players

```lua
local Anchor = require(game.ServerScriptService.Anchor)

local Data = Anchor.new("Main", {
	Coins = 0,
	Items = {},
})

Data:Bind()
```

That one `Bind` call does what every ProfileStore game writes by hand:

- starts a session for each player on join (and for players already in the server),
- key `"Player_" .. UserId` (change the prefix with `KeyPrefix`),
- `AddUserId`, then `Reconcile` against your template,
- kicks the player if the data can't be loaded within 120 seconds, or if another server takes the session,
- ends the session when they leave; shutdown saves everyone (ProfileStore's `BindToClose`).

## Read and change data

```lua
-- Right now (nil if the player isn't loaded yet)
local profile = Data:Get(player)
if profile then
	print(profile.Data.Coins)
end

-- Wait for it (nil if the player leaves first)
local profile = Data:Await(player)

-- Change it (returns false if the player isn't loaded)
Data:Update(player, function(data)
	data.Coins += 100
	table.insert(data.Items, "Sword")
end)
```

`profile.Data` is a plain table and stays the same table for the whole session, so you can also keep a
reference and write to it directly. Anchor autosaves every 5 minutes and saves when the player leaves.

## React to players

```lua
Data.Loaded:Connect(function(player, profile)
	print(player.Name, "has", profile.Data.Coins, "coins")
end)

Data.Leaving:Connect(function(player, profile)
	profile.Data.LastSeen = os.time() -- still saved: fires before the session ends
end)
```

`Bind` takes a few options if you need them:

```lua
Data:Bind({
	Key = function(player) return "PLAYER_" .. player.UserId end, -- custom key
	OnLoaded = function(player, profile) end,                     -- same as Data.Loaded
	KickMessage = "Your data could not be loaded. Please rejoin.",
	LoadTimeout = 120,                                            -- seconds before the kick
})
```

## Pair it with Ripple

[Ripple](https://acidgorgon.github.io/ripple/) replicates state to clients by wrapping a plain table in
place. Tell Anchor how to wrap each profile and every Anchor write (`Update`, trades, gifts, receipts)
goes through Ripple, so clients see it the same frame:

```lua
local Ripple = require(game.ReplicatedStorage.Shared.Ripple.Server)

Data:UseRipple(function(player, profile)
	return Ripple.Club.new(player, profile.Data)
end)

Data:Update(player, function(club)
	club.Cash += 50 -- `club` is the Ripple state: saved AND replicated
end)
```

More in [Using with Ripple](/guide/ripple).

## Next

- [Studio test options](/guide/studio-testing): mock data, reset, play as another player.
- [Trades and anti-dupe](/guide/trades): `Anchor.Trade`, gifts and receipts.
- [API reference](/reference/api): everything else.
