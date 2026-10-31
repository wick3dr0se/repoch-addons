# Project Epoch Reborn Addon Collection

A collection of addons for Project Epoch Reborn.

## Addons

### Epoch-specific

| Addon | Type | What it is |
|-------|------|-------------|
| [ElvUI_pfQuest](ElvUI_pfQuest/) | Quest helper | pfQuest 7.0.1 with everything pfQuest Epoch added for this server: quest, item, object and unit data, continent pins, nameplate quest icons, the loot panel and quest announcements. ElvUI-native UI with its settings in the ElvUI panel. Fork of [pfQuest Epoch](https://github.com/Bennylavaa/pfQuest-epoch). |

### Fine on any 3.3.5a

| Addon | Type | What it is |
|-------|------|-------------|
| [ElvUI](ElvUI/) | UI replacement | Fork of [ElvUI Epoch](https://github.com/Bennylavaa/ElvUI-Epoch) v6.11 with performance work across nameplates, auras, unit frames, tags, portraits and garbage collection. The folder stays `ElvUI` so plugins resolving `Dependencies: ElvUI` keep working. |
| [ElvUI Seal Twist](ElvUI_SealTwist/) | ElvUI plugin | Paladin seal-twisting helper for the swing bar: highlights the twist window and shows which seal to cast next. Needs TBC-style talent trees. |
| [ElvUI Damage Meter](ElvUI_DamageMeter/) | ElvUI plugin | Minimal damage meter. Tracks damage per spell with DPS, hit count and averages. |

## Install

Download the addon folder(s) you want and drop them into your WoW `Interface/AddOns/` directory.

```
Wow/
  Interface/
    AddOns/
      ElvUI/
        ElvUI.toc
        (Core/, Modules/, Libraries/, Media/, ...)
      ElvUI_OptionsUI/
        ElvUI_OptionsUI.toc
        (Core.lua, Maps.lua, Libraries/, Locales/, ...)
      ElvUI_SealTwist/
        ElvUI_SealTwist.toc
        ElvUI_SealTwist.lua
```

`ElvUI` replaces the stock ElvUI install. `ElvUI_OptionsUI` ships beside it in this repo, so copy both folders: the in-game config panel loads from it.

### One addon, no clone

```bash
cd "Wow/Interface/AddOns"
curl -sSL https://github.com/wick3dr0se/repoch-addons/archive/refs/heads/main.tar.gz | tar -xz --strip-components=1 "repoch-addons-main/ElvUI_SealTwist"
```

Swap `ElvUI_SealTwist` for any addon folder above and it lands as `Interface/AddOns/ElvUI_SealTwist/`. Installing `ElvUI` this way needs `ElvUI_OptionsUI` fetched too, since the config panel lives in that folder.

## Licences

Each addon keeps its upstream licence.

- `ElvUI/` and `ElvUI_OptionsUI/` are under Tukui's custom licence: free to use, modifications for private use or on GitHub, folder names unchanged, copyright notice kept. See `LICENSE.txt` in each folder, and `ThirdPartyNotices.md` for the bundled libraries (Ace3, oUF, LibSharedMedia and others).
- `ElvUI_pfQuest/` carries pfQuest's MIT text as `LICENSE-pfQuest-MIT` and pfQuest Epoch's licence as `LICENSE`, which governs it.
- `ElvUI_SealTwist/` and `ElvUI_DamageMeter/` are ours.

## Compatibility

Only `ElvUI_pfQuest` is tied to this server: it ships the quest data, and the engine it is built on has nothing to show without it. Everything else is a general addon and runs anywhere 3.3.5a does.

3.3.5a runs embedded Lua 5.1. No `C_Timer`, `SetColorTexture`, `CombatLogGetCurrentEventInfo`, `BackdropTemplateMixin`, or other retail APIs.
