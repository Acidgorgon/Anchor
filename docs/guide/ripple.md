# Using with Ripple

[Ripple](https://acidgorgon.github.io/ripple/) replicates state to clients. Anchor saves it. They meet at
one table: `profile.Data`.

- Ripple wraps `profile.Data` **in place**: `Ripple.Club.new(player, profile.Data)` writes straight through
  to the same plain table Anchor saves.
- Anchor never replaces `profile.Data` and never puts metatables in it, so the wrap stays valid for the
  whole session.

## Setup

```lua
local Anchor = require(game.ServerScriptService.Anchor)
local Ripple = require(game.ReplicatedStorage.Shared.Ripple.Server)

local Data = Anchor.new("Main", Template)

Data:UseRipple(function(player, profile)
	return Ripple.Club.new(player, profile.Data)
end)

Data:Bind()
```

`UseRipple` runs your function once per loaded player (including players already loaded when you call
it) and remembers the state it returns. From then on every write **Anchor** makes goes through that
state, so it is validated by Ripple's schema and replicated:

| Anchor call | Writes through Ripple |
|---|---|
| `Data:Update(player, fn)` | `fn` receives the Ripple state instead of `profile.Data` |
| `Anchor.Trade(a, b, fn)` | both players' changes |
| `Data:Gift(...)` | the gift's changes, when it is applied |
| `Data:ProcessReceipt` / `HandleReceipts` | the grant's changes |
| `Data:Reset(player)` | the refill from the template |

```lua
Data:Update(player, function(club)
	club.Cash += 50 -- saved by Anchor, replicated by Ripple
end)
```

## Trades replicate in one frame

`Anchor.Trade` applies both players' changes through their Ripple states in the same frame, so both
clients see the trade at once. Your trade function still works on plain copies; only the final
changes go through Ripple.

If Ripple's schema rejects a write (for example a field the schema doesn't know), Anchor writes that value
straight into `profile.Data` instead and fires `Anchor.OnError`. The data stays correct and saved; only
the replication of that one field is missed. A trade is never left half applied.

To use states other than the `UseRipple` ones for a single trade:

```lua
Anchor.Trade(profileA, profileB, fn, { Live = { clubA, clubB } })
```

## Write through Ripple, not around it

```lua
local club = Ripple.Club.new(player, profile.Data)
club.Cash += 1          -- replicated and saved
profile.Data.Cash += 1  -- saved, but NOT replicated or validated
```

## Skipping clean saves with Ripple's dirty flag (advanced)

Ripple tracks whether a state has unsaved writes (`Ripple.isDirty` / `Ripple.clearDirty`). Anchor can use
that to skip an autosave when nothing changed, through two store options:

```lua
local clubs = setmetatable({}, { __mode = "k" }) -- [profile] = Ripple state

local Data = Anchor.new("Main", Template, {
	IsDirty = function(profile)
		local club = clubs[profile]
		return club == nil or Ripple.isDirty(club)
	end,
	ClearDirty = function(profile)
		local club = clubs[profile]
		if club then Ripple.clearDirty(club) end
	end,
})

Data:UseRipple(function(player, profile)
	local club = Ripple.Club.new(player, profile.Data)
	clubs[profile] = club
	return club
end)
```

::: warning
Only do this if **every** write to the data goes through Ripple. A direct write to `profile.Data`
doesn't set the dirty flag, and a skipped autosave would leave it unsaved until the next real save.
:::

Skipping only happens when a skip can't make the session lock look stale. With the default 300-second
autosave that is never, so this matters only if you lower `AUTO_SAVE_PERIOD` with
`Anchor.SetConstant`. See [Benchmarks](/benchmarks#datastore-calls).
