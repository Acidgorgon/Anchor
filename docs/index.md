---
layout: home

hero:
  name: Anchor
  text: Player data that stays put
  tagline: Session-locked DataStore saving for Roblox. A drop-in upgrade of ProfileStore with dupe-proof trades, exactly-once receipts, smaller saves and a three-line setup.
  image:
    src: /family/anchor.svg
    alt: Anchor
  actions:
    - theme: brand
      text: Get started
      link: /guide/getting-started
    - theme: alt
      text: Coming from ProfileStore
      link: /guide/migrating
    - theme: alt
      text: GitHub
      link: https://github.com/Acidgorgon/anchor

features:
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/><path d="m9 12 2 2 4-4"/></svg>
    title: Never lose data
    details: ProfileStore's session lock, autosave and shutdown saving, unchanged. On top, a quick rejoin never loads stale data, a damaged save is never overwritten, and a rejected save names the exact field that broke it.
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7 4 3 8l4 4"/><path d="M3 8h14"/><path d="m17 20 4-4-4-4"/><path d="M21 16H7"/></svg>
    title: Dupe-proof trades
    details: "Anchor.Trade(a, b, fn) moves items between two players so that a crash or rollback can never duplicate or delete them. Receipts and gifts are applied exactly once."
  - icon: <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 14h6v6"/><path d="M20 10h-6V4"/><path d="m14 10 7-7"/><path d="m3 21 7-7"/></svg>
    title: Smaller saves
    details: The opt-in Compact format stores a 112 KB card collection in 39 KB. Old ProfileStore servers can't load a Compact profile, so they can never wipe it.
---

::: tip Made with Claude
Most of Anchor was written with [Claude](https://claude.ai), Anthropic's AI, to speed up my own Roblox workflow. Issues and pull requests are welcome.
:::

## Quick start

::: code-group

```lua [ServerScriptService/Data.server.luau]
local Data = require(game.ServerScriptService.Anchor).new("Main", { Coins = 0, Items = {} })
Data:Bind() -- loads on join, saves on leave and shutdown
Data:Update(player, function(data) data.Coins += 10 end) -- wherever you have a player
```

```lua [With options]
local Anchor = require(game.ServerScriptService.Anchor)

local Data = Anchor.new("Main", { Coins = 0, Items = {} }, {
	Format = "Compat",     -- default; "Compact" once every old server is gone
	KeyPrefix = "Player_", -- default; keys are KeyPrefix .. UserId
})
Data:Bind()
```

:::

Drop the `Anchor` module into `ServerScriptService` and that's it. Already on ProfileStore? Swap the
`require` and your code keeps working: [Migrating from ProfileStore](/guide/migrating).
