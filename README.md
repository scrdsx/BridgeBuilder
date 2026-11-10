# Bridge Builder - Last Bridge Standing

Builds a bridge for you in [Last Bridge Standing](https://www.roblox.com/games/88943954655371) using the game's own rule modules,
so every beam is checked before it is sent and the bridge is drawn by the game itself.

```
loader.lua        the loadstring target; fetches every file in src/ and runs them
version.txt       current version
src/main.lua      the window (Builder / Info / Settings tabs)
src/bridgebot.lua planner + sender (reads the round, plans a truss, pushes it through the game's controller)
src/ui.lua        UI library (shared with Scrdsx Solutions)
src/logo.lua      logo, src/icons.lua  tab icons
tools/bridge_dump.lua   one-shot dump of the game (scripts, rules, remotes) for development
build.py          optional single-file bundle -> dist/BridgeBuilder.lua
```

## Loadstring
```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/scrdsx/BridgeBuilder/main/loader.lua"))()
```

RightShift hides the menu. The log is written to `BridgeScript_log.txt` in the executor workspace.

New module: add `src/<name>.lua`, add it to `MODULES` in `loader.lua` and `order` in `build.py`.
