# Studio test options

One option on `Anchor.new` changes how data loads while you test in Studio. No extra modules, no wrapper
service.

```lua
local Data = Anchor.new("Main", Template, { Mock = true })     -- in-memory store
local Data = Anchor.new("Main", Template, { Reset = true })    -- fresh template on every join
local Data = Anchor.new("Main", Template, { PlayAs = 123456 }) -- play on someone else's save
local Data = Anchor.new("Main", Template, { View = 123456 })   -- read-only look, never saves
local Data = Anchor.new("Main", Template, { NoSave = true })   -- your own save, never written
```

When any of these is active, Anchor prints which ones in the output, for example
`[Anchor]: Store "Main" dev options: Reset`.

## What each option does

| Option | Value | What happens |
|---|---|---|
| `Mock` | `true` | Every call on this store uses an in-memory store. Nothing touches the real DataStore. Data lives until the test session ends. |
| `Reset` | `true` | Every join starts from the template. The session is real and is saved, so the old data stays in the key's version history (Anchor never calls `RemoveAsync`). |
| `PlayAs` | UserId | The **first** player to join plays on that user's save. Changes are saved to it. Their `UserIds` aren't touched. Everyone else loads their own save. |
| `View` | UserId | Every player who joins gets a read-only copy of that user's save. `Update` works in memory, nothing is ever written and no session lock is taken. |
| `NoSave` | `true` | Your own save, loaded read-only: never written, no session lock. A player with no save gets the template. |
| `KeyPrefix` | string | Not a dev option (works live too): `Bind`, `Send` and `Gift` use `KeyPrefix .. UserId` as the key. Default `"Player_"`. |

`PlayAs` and `View` find the target's save the same way `Bind` finds everyone's: `KeyPrefix .. UserId`, or
your `Bind({ Key = ... })` function called with a stand-in player whose `UserId` is the target's. If your
`Key` function can't build that key (it errors or returns nothing), the player is kicked with an
`OnError` report; Anchor never falls back to another save.

`Data:Reset(player)` does the same as `Reset` mid-session: it refills that player's data from the
template in place (through the Ripple state if you use one) and returns `true`.

::: warning PlayAs and Reset write real data
`PlayAs` and `Reset` start a normal session and save. If Studio has DataStore access, they change the real
save (the previous version stays in version history). Combine them with `Mock = true`, or use `View` /
`NoSave`, if you only want to look.
:::

::: tip
`View` and `NoSave` profiles are read-only. For those players `Anchor.Trade` returns
`false, "Invalid"`, receipts return `NotProcessedYet`, and gifts and `Send` messages are not handled: they
wait in the save's queue for the next real session.
:::

## No-code toggles: attributes

Set the same options as attributes on the `Anchor` ModuleScript (Properties panel, Attributes, `+`):

| Attribute | Type |
|---|---|
| `Mock`, `Reset`, `NoSave` | boolean |
| `PlayAs`, `View` | number (a numeric string works too) |

Attributes apply to every store created with `Anchor.new` (and stock-style `Anchor.New`). An option passed
in code always wins, even `false`:

```lua
-- The ModuleScript has Reset = true, but this store ignores it:
local Settings = Anchor.new("Settings", Template, { Reset = false })
```

## Studio-only guard

Dev options can lose or overwrite real saves, so they only work in Studio
(`RunService:IsStudio()`). On a live server every dev option and attribute is ignored, and Anchor prints
one warning per store:

```text
[Anchor]: Store "Main": dev options (Reset) are IGNORED on this live server - they would lose or
overwrite real saves. Remove them (check the Anchor ModuleScript's attributes), or pass
AllowDevOptionsLive = true for a private test place.
```

`Data:Reset(player)` also refuses on a live server: it warns and returns `false`.

For a private test place you can turn them on live, in code only (there is no attribute for this):

```lua
local Data = Anchor.new("Main", Template, { Reset = true, AllowDevOptionsLive = true })
```

::: danger
Never ship `AllowDevOptionsLive = true` in your real game. With it, a forgotten `Reset` attribute wipes
every player who joins.
:::

## Studio without API access

If the place isn't published or **Enable Studio Access to API Services** is off, Anchor does what
ProfileStore does: it prints `Roblox API services unavailable - data will not be saved` and keeps all data
in memory. You don't need `Mock` for that case.
