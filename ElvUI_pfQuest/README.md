# ElvUI_pfQuest

Quest helper and quest database for **Project Epoch Reborn** (WoW 3.3.5a), with a UI written for ElvUI instead of pfUI. It ships Epoch's quest, item and object data, so it is specific to this server; the engine is stock pfQuest, but without the data there is nothing to show.

Two upstreams merged into one addon:

| Upstream | What it contributes |
|---|---|
| [pfQuest-wotlk](https://github.com/shagu/pfQuest) 7.0.1 (MIT) | engine, node/route system, base quest database, map and minimap pins, arrow, browser, journal |
| [pfQuest-epoch](https://github.com/Bennylavaa/pfQuest-epoch) 3.3.0 | Epoch quest/item/object overlay, continent pins, tooltip progress, nameplates, loot panel, announce, quest automation |

Neither works on Epoch without the other, so they ship as one addon: one TOC, one load order, no `Dependencies` chain, and the ElvUI settings page built in rather than a second addon.

## What changed from upstream

- **pfUI is gone.** pfQuest called `pfUI.api.*` for every frame it owns and shipped a fake pfUI table when pfUI was absent. There is no `pfUI` table anywhere in this addon now: everything draws through `elvui.lua`, a `pfq` module that reads ElvUI media, fonts and border colors at call time.
- **pfQuest-epoch is vendored in.** Its files live here, converted from `pfUI.api.*` to `pfq.*`. Its own config renderer (`pfQuest-config.lua`, the ~10-frame `VARIABLES_LOADED` rebuild) and its updater are deleted.
- **The settings window is gone.** `config.lua` used to be a 447-line frame; all that survives is what the rest of the addon needs: `pfQuestConfig.path`/`.folder`/`.version`, `LoadConfig()` seeding `pfQuest_config` from `defconfig.lua`, and `MigrateHistory()`. The settings themselves live in the ElvUI panel (`options.lua` + `settings.lua`), and `/db config` opens it.
- **The UI is ElvUI native:** tracker, quest browser (`browser_elvui.lua`), settings page, world map dropdown, quest log language menu, first-run window (`wizard.lua`), journal and map right-click menu.
- **Load order preserved:** base DB (`init/data.xml`, `init/enUS.xml`) → code (`init/addon.xml`) → Epoch overlay (`init/data-epoch.xml`, `init/enUS-epoch.xml`) → Epoch modules (`init/epoch.xml`).

## Rewritten UI

- `tracker.lua` — ElvUI backdrop and font, ElvUI mover for the position, one shared 10 Hz ticker for the map-hover highlight instead of an `OnUpdate` per row. Same contract as upstream (`Reset`, `ButtonAdd`, `ButtonEvent`, `mode`).
- `browser_elvui.lua` — ElvUI window, scroll frames and buttons, four tabs, live search, favourites. An empty search box browses the table instead of showing a blank window. Dropped on purpose: the per-item drop/vendor/reference sub-buttons and the alliance/horde row icons.
- `wizard.lua` — first-run marker mode picker, ElvUI cards and a flat accent check box.
- `options.lua` / `settings.lua` — the ElvUI settings page, generated from `pfQuest_defconfig`, and the `/pfq` command.
- `menu.lua`, `journal.lua`, `elvui.lua` — every remaining frame is drawn with `pfq`.

## Not changed

The database, node/route engine, map and minimap pins, arrow and quest tracking behave as upstream.

Only enUS database files are vendored (other locale directories are removed to keep the repo small), so non-English clients get English data.

## Database

The data is not ours to maintain. Base quests, NPCs, objects and items come from shagu's pfQuest verbatim; the Epoch overlay comes from pfQuest-epoch verbatim. Both are pinned in `data/upstream.lock` with a checksum per file, and `tests/db_provenance_spec.lua` fails if a vendored file is hand edited. Real corrections belong in [`data/local/`](data/local/README.md), applied after upstream, so a refresh cannot silently undo them. There the merge is by field, so a correction names only the fields that differ, and `"_"` deletes a field or a row. An epoch row replaces the row it targets, which is why their files restate every field.

At runtime the database ships packed. `db/packed/` holds one blob per table: `tools/pack_db.lua` builds the merged tables, packs nested values (spawn coordinates, drop tables, quest relations) into compact strings, and writes them as string constants. The client lexes those instead of compiling the sources, then builds a table the first time something reads it, and releases the blob. Login no longer pays for data a session never touches.

```bash
lua5.1 tools/sync_data.lua            # what changed upstream, as row counts
lua5.1 tools/sync_data.lua --update   # accept it
lua5.1 tools/lock_data.lua            # re-pin the checksums
lua5.1 tools/pack_db.lua              # regenerate db/packed/
```

`/pfq status` reports which tables are built and which are still packed. It reads the pack manifest, never the data, so asking cannot trigger the build it reports.

Editing `db/*.lua` by hand is pointless: the client only reads `db/packed/`. Edit the sources, run the packer.

## Install

```
Interface/AddOns/
  ElvUI_pfQuest/
```

Requires ElvUI. Delete any `pfQuest-wotlk`, `pfQuest-epoch` or `ElvUI_pfQuest` folder first — running two copies means two databases and doubled pins, and the settings panel is part of this addon now.

Saved variables are per addon folder, so move them once, into the files this addon reads:

| From | To | Variables |
|---|---|---|
| `pfQuest-wotlk.lua` (character) or `pfQuest-epoch.lua` | `ElvUI_pfQuest.lua` (character) | `pfQuest_config`, `pfBrowser_fav`, `pfQuest_history`, `pfQuest_colors`, `pfQuest_server`, `pfQuest_track` |
| `pfQuest-*.lua` (account) | `ElvUI_pfQuest.lua` (account) | `pfQuest_questcache`, `pfQuest_epochcount`, `pfQuest_CompletedQuestData` |

The identity colour is fixed at pfQuest's mint (`#33ffcc`), the same way the other addons in this collection fix theirs. Nothing to configure.

## Settings

`/ec` → **pfQuest**, or `/pfq`. One group per pfQuest header, plus the Epoch entries. Every control writes pfQuest's own `"1"`/`"0"` strings and calls `ResetAll()`, so changes apply without a reload.

## Syncing with upstream

The base pfQuest side is frozen upstream (last commit August 2025), so only the epoch half needs refreshing — and it is refreshed often (its database changed almost weekly through September 2026).

Data goes through the tools above, not by hand:

```bash
lua5.1 tools/sync_data.lua --source=epoch   # prints the row diff, nothing written
lua5.1 tools/sync_data.lua --update         # write the changed db files
lua5.1 tools/lock_data.lua && lua5.1 tools/pack_db.lua
```

Code files still need the copy and rewrite, because they are rewritten for ElvUI:

```bash
cd ~/.hermes/cache/scratch/pfq/pfQuest-epoch && git pull          # or clone it first
rsync -a img/ "$REPO/ElvUI_pfQuest/"                             # art
for f in patchtable.lua pfQuest-worldmap.lua pfQuest-tooltip.lua pfQuest-lootpanel.lua \
         pfQuest-nameplates.lua pfQuest-announce.lua pfquest-questlog.lua pfquest-arrow.lua; do
  cp "$f" "$REPO/ElvUI_pfQuest/$f"
done
cp overwrites.lua "$REPO/ElvUI_pfQuest/epoch-overwrites.lua"
# then re-apply the pfUI -> pfq rewrite in those files, lint, run the specs
```

The rewrite is five substitutions: `pfUI.api.` → `pfq.`, `pfUI.font_default` → `pfq.font`, `pfUI_config.global.font_size` → `pfq.fontSize`, `pfUI.minimap` → `pfq.minimap`, remaining `pfUI` → `pfq`. `pfQuest-config.lua` and `pfQuest-updater.lua` are the two files that stay deleted. `tests/pfquest_defconfig_spec.lua` fails if any `pfUI` reference survives.

Upstream commit this tree is built from: `5c64470` (3.3.0, 2026-09-09).

## Commands

| Command | Effect |
|---|---|
| `/db config` | opens the ElvUI settings page |
| `/db tracker` | shows the quest tracker |
| `/db lock` | locks/unlocks the tracker |
| `/db locale` | database locale |
| `/db help` | full list |
| `/pfq` | opens the ElvUI settings page |
| `/pfq status` | versions, per-table row counts, which tables are built or still packed |

## Tests

Headless Lua 5.1 specs run the real files against a WoW mock, no client needed:

```bash
cd ElvUI_pfQuest
lua5.1 tests/core_spec.lua               # boot, settings page, /db config redirect, /pfq status
lua5.1 tests/pfquest_defconfig_spec.lua  # real defconfig -> ElvUI controls, no pfUI left
lua5.1 tests/elvui_api_spec.lua          # the pfq backend contract
lua5.1 tests/fork_ui_spec.lua            # tracker layout and persistence, tickers, browser
lua5.1 tests/config_spec.lua             # config seeding, history migration, saved tables
lua5.1 tests/db_pack_spec.lua            # decode every packed table back and compare to the sources
lua5.1 tests/db_lazy_spec.lua            # nothing builds at load, subtables build on demand
lua5.1 tests/db_provenance_spec.lua      # vendored data still matches its upstream pins
```

`db_pack_spec` is the one that matters when touching the packer: it walks every row and every field of fifteen tables after decoding, so a lost coordinate or drop table fails a test instead of shipping as a silent nil.

## License

The merge keeps both upstream licenses, because they differ:

- `LICENSE` — **pfQuest-epoch**, the stricter one, which governs this addon. It permits GitHub forks with attribution, forbids redistribution elsewhere, and requires the derivation to be stated with a link back to the original repository. The name and this file say both.
- `LICENSE-pfQuest-MIT` — **pfQuest** by Shagu, MIT, retained as required.

Not affiliated with or endorsed by either upstream, and not the official pfQuest-epoch. `EPOCH-README.md` is the upstream readme, kept verbatim.
