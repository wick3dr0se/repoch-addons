# data/local

Our own corrections to the quest database. Applied after the vendored tables:
shagu's base first, then pfQuest-epoch's overlay, then these. A refresh of either
upstream cannot undo a correction kept here.

One file per table, named after it: `quests.lua`, `items.lua`, `units.lua`,
`meta.lua`, `minimap.lua`, `zones.lua`, `objects.lua`, `professions.lua`,
`areatrigger.lua`, `refloot.lua`, `quests-itemreq.lua`.

```lua
-- data/local/quests.lua
pfDB["quests"]["data-local"] = {
	[1234] = { ["level"] = 60 },  -- merges: fields not named here stay as upstream has them
	[5678] = "_",                 -- deletes the row
}
pfDB["quests"]["enUS-local"] = { [1234] = "Corrected name" }
```

The suffix is always `local`, where the shipped overlays use `epoch`:
`data-local` for row tables, `enUS-local` (and `loc-local`) for the name tables,
and `minimap-local` / `meta-local` at the top level for the two tables that are
not row based.

Merge is by field, unlike an epoch row which replaces the row it targets. That is
deliberate: a correction usually changes one value, and restating the whole row
would drop every field upstream added later. A `"_"` deletes the field it is set
on, or the row when it is set on the row key.

`lua5.1 tools/pack_db.lua` picks these up and prints how many it applied.
`tests/db_local_spec.lua` proves the order, the merge and the deletion rules.
