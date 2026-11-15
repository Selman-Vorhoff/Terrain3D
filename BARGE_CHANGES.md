# Barge Game changes to Terrain3D

This is the Barge Game fork of [Terrain3D](https://github.com/TokisanGames/Terrain3D).
It is kept beside upstream so we can merge new stable releases and check any problem
against stock.

## Rules

- **Base:** each fork branch starts from an upstream stable tag. `barge/1.1` starts at
  `v1.1.0-stable` (629bbd6). We never take unreleased upstream `main`.
- **Updating:** a new stable release (say `v1.2.0-stable`) is merged into a new branch
  `barge/1.2`, not rebased, so our changes stay readable and conflicts only appear where
  we changed code.
- **Remotes:** `origin` is the fork (`Selman-Vorhoff/Terrain3D`), `upstream` is
  `TokisanGames/Terrain3D`.
- **One commit per change**, with a body saying what and why, and one entry below.
- **Platforms:** only Windows x86_64 and Linux x86_64 are built and supported.
- **Stock check:** the game keeps the stock release binaries and a switch script
  (`tools/terrain3d_fork/` in the game repository), so any bug can be checked against
  stock with a world that stock can load.
- **Upstream absorbs a change:** mark the entry "merged upstream" and drop our version
  at the next merge.

`git diff v1.1.0-stable..barge/1.1` shows everything we changed.

## Entry format

Each change gets a section:

- **What:** the behaviour change, in one or two sentences.
- **Why:** the game need.
- **Files:** the files it touches.
- **Test:** how to check it (fork test name, manual check).
- **Upstream:** none / issue / PR / merged upstream.

## Changes

### 1. Godot 4.7 editor compatibility (addon scripts)

- **What:** `double_slider.gd` reads the editor scale with `EditorInterface.get_editor_scale()`
  instead of the `interface/editor/display_scale` setting, which can be Nil in Godot 4.7.
  `export_plugin.gd` takes the version hash from the plugin instead of the selected terrain
  node, so a command-line export with no Terrain3D selected does not fail.
- **Why:** the game runs Godot 4.7.2. These two edits were made in the game's installed
  addon during the 4.7 upgrade (game commit bcd0c1bdf); the fork carries them so installing
  fork builds does not undo them.
- **Files:** `project/addons/terrain_3d/src/double_slider.gd`, `project/addons/terrain_3d/src/export_plugin.gd`.
- **Test:** open the game in the 4.7.2 editor (no DoubleSlider errors); headless export.
- **Upstream:** none (upstream targets Godot 4.5).

### 2. Region file names for any signed location

- **What:** `Terrain3DUtil::string_to_location` (behind `filename_to_location`) reads each
  coordinate as a sign character (`_` positive, `-` negative) followed by any number of
  digits, so `terrain3d_100-1234.res` is region (100, −1234). Malformed names, and values
  outside int32 or equal to the reserved error value `INT32_MAX`, are rejected with an error.
  The writer is unchanged: it already widened past two digits, only the reader cut every
  coordinate to three characters.
- **Why:** the region window (change 4) allows regions far from the origin. At 0.25 m and
  256 m regions, a 65 km world needs locations up to ±127, and stock misreads any
  coordinate of 100 or more (`_100_00` read back as (10, 0)).
- **Compatibility:** names for locations in −99..99 are byte-for-byte the stock names, so
  every stock data folder loads unchanged, and stock can still read our folders as long as
  they stay inside its ±16 window.
- **Files:** `src/terrain_3d_util.cpp`.
- **Test:** `project/tests/test_region_filenames.gd` (stock names unchanged, round trips up
  to int32 limits, uniqueness, malformed names rejected, a stock-named folder loads with the
  right heights). The disk round trip at locations beyond ±16 is in the region-window test.
- **Upstream:** none yet; candidate for a PR together with the window change.

### 3. Fixed slot pool for region textures ("streaming")

- **What:** `Terrain3DData.enable_streaming(slot_capacity)` switches an empty data object to a
  fixed-capacity slot pool. A region then holds a stable slot (its texture array layer);
  adding or evicting one uploads one layer per map type and changes one region map entry.
  No texture array rebuild, no shader rebuild and no collision body rebuild. While
  streaming, `add_region` / `remove_region` route to `add_region_streamed` /
  `evict_region`, so callers keep the classic API (`p_update = false` batches the signals
  until `update_maps()`). Eviction forgets the region; it never writes or deletes files.
  `get_streaming_stats()` reports slots in use, inserts, evictions, upload time and memory.
  Without `enable_streaming` nothing changes (golden test).
- **Why:** stock rebuilds every texture array, re-enumerates region ids and rebuilds the
  whole collision body on every add or remove. Streaming regions around the barge needs
  add/evict to cost one region, not the whole world.
- **Origin:** the data layer of upstream draft PR #1004 (TokisanGames/Terrain3D), without its
  disk streamer and editor parts. Our differences:
  - The arrays are allocated at the first insert as copies of that region's maps, so their
    formats match whatever the region carries (#1004 hard-codes uncompressed RGBA8 colour,
    which breaks compressed colour maps). Later regions are checked against that format.
  - The material uploads the per-slot location table (`get_shader_region_locations`);
    #1004 kept uploading the dense list, which does not match slot-indexed layers.
  - Uses `get_active_color_map()` and applies the runtime colour compression rules of
    `add_region`.
  - Collision: `Terrain3D` no longer connects `region_map_changed` straight to collision
    `build()`; `_on_region_map_changed` skips it while streaming. Inserts and evictions
    call `Terrain3DCollision::region_changed`, and dynamic collision refreshes its shapes in
    place once per batch when the region can touch the area around the target (full
    collision is rebuilt).
  - Evicting a region also drops instancer updates queued for it (otherwise "Errant null
    region" warnings).
  - Capacity is capped by `Terrain3DMaterial.max_regions` (the shader's layer bound).
  - The editor is refused (`enable_streaming` is runtime only); `set_region_locations`,
    `change_region_size` and `load_directory` refuse while streaming.
  - #1004's material `FULL_REBUILD` fix is not needed: v1.1.0-stable already tests all bits.
- **Files:** `src/terrain_3d_data.{h,cpp}`, `src/terrain_3d.{h,cpp}`,
  `src/terrain_3d_collision.{h,cpp}`, `src/terrain_3d_instancer.{h,cpp}`,
  `src/terrain_3d_material.cpp`.
- **Test:** `project/tests/test_slot_pool.gd`: batched and single inserts, replacement keeps
  the slot, 500 random add/evict operations with invariants every 50 (free slots, unique
  slots, shader table, has_region, heights), texture array RIDs unchanged, non-resident
  answers, collision refreshed in place under the target with the body RID unchanged,
  exhaustion, refused operations. Run it with `--windowed` too: headless uses a dummy
  renderer and does not upload textures.
- **Upstream:** draft PR #1004 covers the idea; our fixes above could go back to it.
