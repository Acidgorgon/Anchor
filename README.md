# Anchor

Session-locked DataStore saving for Roblox: a drop-in upgrade of loleris' ProfileStore with dupe-proof
trades, exactly-once receipts, smaller saves and a three-line setup.

```lua
local Anchor = require(game.ServerScriptService.Anchor)

local Data = Anchor.new("Main", { Coins = 0, Items = {} })
Data:Bind() -- loads on join, saves on leave and shutdown
Data:Update(player, function(data) data.Coins += 10 end)
```

**Docs: https://acidgorgon.github.io/Anchor/** ([getting started](https://acidgorgon.github.io/Anchor/guide/getting-started),
[migrating from ProfileStore](https://acidgorgon.github.io/Anchor/guide/migrating),
[API reference](https://acidgorgon.github.io/Anchor/reference/api)).

> [!NOTE]
> **Made with Claude.** Most of Anchor was written with [Claude](https://claude.ai), Anthropic's AI, to speed up my own Roblox workflow. Issues and pull requests are welcome.

Part of a family of Roblox libraries: [Current](https://acidgorgon.github.io/Current/) (networking),
[Ripple](https://acidgorgon.github.io/ripple/) (state sync) and Anchor (saving).

Status: in development. Design notes: [docs/design/spec.md](docs/design/spec.md).
`reference/` holds an unmodified copy of ProfileStore 1.0.3 (Apache-2.0, (c) loleris / MAD STUDIO), used as the
behavioural reference and in compatibility tests.
