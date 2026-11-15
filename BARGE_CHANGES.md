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
- **Upstream absorbs a change:** compare upstream's version with every behaviour the
  entry lists, our fixes included. Drop our version at the next merge only when all are
  covered and the fork tests plus the game checks pass on Windows and Linux; otherwise
  keep the missing parts as a smaller entry. Mark the entry "merged upstream" with what
  replaced what.

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
  - Capacity is capped by `Terrain3DMaterial.max_regions` (the shader's layer bound), and
    on D3D12 by 4096 subresources (layers × mip levels) per array, the game importer's
    safety limit (`D3D12_POOL_SUBRESOURCE_LIMIT`). The arrays take their whole capacity at
    the first insert, so that insert is refused before anything is allocated; the error
    names the largest capacity that fits (585 slots for 64 px colour maps with mipmaps,
    372 for 1024 px). Stats report `bytes_allocated` (whole capacity) and `bytes_resident`.
  - The editor is refused (`enable_streaming` is runtime only); `set_region_locations`,
    `change_region_size` and `load_directory` refuse while streaming.
  - Changing a resident region: `update_maps()` re-uploads the layers of resident regions
    that changed since their upload: written through `set_pixel` / `set_height` and the
    other setters, given new map images (`region.set_height_map`), flagged edited, or all
    of them after a full colour mipmap regeneration. Unchanged regions cost nothing, so
    `add_region(r, false)` … `update_maps()` stays cheap. Pixels written straight into a
    region's `Image` are not seen; flag the region edited or add it again (same slot).
  - The pool's layer size, format and mipmap state are fixed at allocation, even after the
    last eviction: `load_region` refuses another region size instead of adopting it.
  - Replacing a resident region first destroys its instancer meshes, so meshes or cells
    the new region lacks stop rendering.
  - `Terrain3DMaterial.max_regions` cannot drop below the slot capacity, and the material
    cannot be replaced while streaming (a new one re-initializes the terrain).
  - `get_height_maps` / `get_control_maps` / `get_color_maps` list the resident regions'
    maps in `get_region_locations()` order, built on demand (not slot order).
  - Collision refresh after an insert or eviction uses a conservative square bound
    (radius + two shape sizes + border), because shapes sit on a snapped grid and sample
    one vertex past their edge.
  - #1004's material `FULL_REBUILD` fix is not needed: v1.1.0-stable already tests all bits.
- **Files:** `src/terrain_3d_data.{h,cpp}`, `src/terrain_3d.{h,cpp}`,
  `src/terrain_3d_collision.{h,cpp}`, `src/terrain_3d_instancer.{h,cpp}`,
  `src/terrain_3d_material.cpp`.
- **Test:** `project/tests/test_slot_pool.gd`: batched and single inserts, replacement keeps
  the slot, 500 random add/evict operations with invariants every 50 (free slots, unique
  slots, shader table, has_region, heights), texture array RIDs unchanged, non-resident
  answers, collision refreshed in place under the target with the body RID unchanged,
  exhaustion, refused operations. Run it with `--windowed` too: headless uses a dummy
  renderer and does not upload textures. `test_pool_d3d12_limit.gd` (D3D12 only:
  `test.py --windowed --driver d3d12`): one slot over the limit is refused with nothing
  resident, the limit itself works. `test_slot_pool_edits.gd`: set_height and new images
  reach the GPU layers, replacement and slot reuse carry all three maps (GPU readback
  when windowed), collision refreshes over an evicted neighbour, a drained pool refuses
  another region size, getters, max_regions and material guards. The instancer change on
  replacement has no automated check (its meshes are bare RenderingServer instances).
- **Upstream:** draft PR #1004 covers the idea; our fixes above could go back to it.

### 4. A region window placed by the game, not fixed at the origin

- **What:** the 32 × 32 region map is a window whose minimum corner
  (`Terrain3DData.set_region_window_origin`, default (−16, −16) = stock) the game places.
  A region is drawn when `location − origin` lies in 0..31. Its map entry wraps around:
  `((loc + 16) & 31)` per axis, so at the default origin the layout is byte-for-byte stock.
  Moving the window changes only the entries of regions that enter or leave it (no shader
  or collision rebuild; since entry 5, regions entering upload their layers). While
  streaming, regions can be added at any location up to ±2^19 (`REGION_LOCATION_LIMIT`, so
  vertex coordinates stay inside int32); resident regions outside the window stay loaded
  for data queries and collision and are not drawn (since entry 5 they hold no GPU slot).
- **Data queries do not depend on the window.** While streaming, `get_region_id` is the slot
  looked up by location, so `has_region`, `get_normal`, `get_pixel`, `get_control`,
  `get_region_idp` and the CPU region blend answer the same for every window position.
  Collision already read regions by location.
- **Classic mode is unchanged:** without `enable_streaming` the window stays at the stock
  default (the setter refuses), and `add_region` still refuses locations outside −16..15,
  because classic region ids are rebuilt from the window.
- **Why:** stock addresses regions absolutely from the origin, which caps a 0.25 m world at
  8 km (256 m regions). In co-op the camera is not the centre of the action, so the game
  places the window (anchored on the barge) instead of a camera-following window.
- **API changes:** `get_region_map_index` is an instance method now (it depends on the
  window); new `set_region_window_origin`, `get_region_window_origin`, `is_in_region_window`;
  `get_streaming_stats` reports `window_origin`, `window_moves`, `slots_in_window`.
  `Terrain3DRegion.set_location` accepts any location within the limit.
- **Shaders:** new uniform `_region_map_origin` (default `ivec2(-16)`) in `main.glsl` and
  `displacement_buffer.glsl`; the lookup in `get_index_coord`, `get_index_uv`, the
  displacement buffer, `check_region` (backgrounds) and the editor's region boundary box
  uses the window. The addon's extra shaders (lightweight, minimum, particle example) got
  the same lookup, and the particle example uploads the origin.
- **Not changed / known limits:** the editor dummies in `ui.gd` compute stock indices, which
  match at the default window, and the editor never moves it. Instancer meshes of resident
  regions outside the window rendered until entry 5, which removed them. With the FLAT world
  background the GPU treats the window edge like the edge of the world (it blends to the
  background there), while the CPU blend only looks at which regions exist, so heights can
  differ in a strip one region wide at the window edge; the game uses background NONE and
  keeps the window far larger than the play area, so this is documented, not fixed.
- **Hardening (Codex review of this change):** the C# wrapper `Terrain3DData.cs` calls
  `get_region_map_index` as an instance method and wraps the new streaming and window API;
  the shaders clamp the region index before reading `_region_locations` (an empty map
  entry is −1); `is_valid_region_location` compares without `ABS` (INT32_MIN overflowed
  it); the window origin is refused if its last region (`origin + 31`, computed in int64)
  would pass the limit; `import_images` is refused while streaming (it adds regions the
  classic way); the particle example converts world to vertex units before its lookup.
- **Files:** `src/terrain_3d_data.{h,cpp}`, `src/terrain_3d_region.cpp`,
  `src/terrain_3d_material.cpp`, `src/shaders/{main,displacement_buffer,backgrounds,editor_functions}.glsl`,
  `project/addons/terrain_3d/extras/shaders/{lightweight,minimum}.gdshader`,
  `project/addons/terrain_3d/extras/particle_example/{particles.gdshader,terrain_3D_particles.gd}`.
- **Test:** `project/tests/test_region_window.gd` (headless: classic refusals and stock
  layout; regions at (±300, ±300), (300, −1234), (−5000, 4000); map invariants and
  unchanged data queries at eight window positions including a 600 region jump; RIDs kept;
  wraparound pair and eviction outside the window; collision far out independent of the
  window; disk round trip with wide names into a fresh directory with heights unique to
  the run; location limits including INT32_MIN and a window reaching the last region).
  `test_region_window_render.gd` and `test_extra_shaders.gd` (windowed only: the GPU draws a
  region exactly when it is inside the window, including the wraparound case; the extra
  shaders compile and follow the window). Golden test: worlds inside ±16 unchanged.
  `tools/terrain3d_fork/test.py` (game repo) fails a test on any engine `ERROR:` line the
  test does not declare with `## expect-error:`.
- **Upstream:** none yet. Upstream #491 asks for this; a PR would follow #1004.

### 5. GPU slots only inside the region window

- **What:** while streaming, only resident regions inside the region window hold a slot
  (texture array layer). A resident region outside the window is CPU data only: it answers
  every data query and feeds collision, but takes no GPU memory, has no instancer meshes,
  and `get_region_id` is −1 for it. When the window reaches it, it takes a slot and uploads
  its three maps (`uploads` in the stats); when the window leaves, the slot returns and its
  instancer meshes are destroyed. `has_region` / `has_regionp` and `get_normal` use
  residency while streaming, not the slot. The slot capacity is now the number of regions
  the game keeps drawn inside the window, not the number resident.
- **Full pool:** adding never fails for lack of a slot. A region inside the window without
  a free slot stays data only, is logged as an error once ("Slot pool exhausted … not
  drawn") and counted in `regions_undrawn`; it takes the next slot that comes free (an
  eviction or the window moving). The data stays usable and the mistake is visible,
  instead of refusing the region.
- **Edits:** `update_maps()` syncs changed resident regions whether drawn or not (entry 3):
  drawn ones re-upload, data-only ones refresh collision, and their current maps are
  uploaded whenever they later take a slot.
- **Why:** in co-op the host keeps physics ground around every remote player
  (`Management/Planning/terrain_streaming_multiplayer.md` in the game repository) but
  never draws it. With a slot per resident region, that ground cost about 13 MB of VRAM
  per region for nothing; six scattered players at 3×3 would need about 1.7 GB on the host.
- **API changes:** `get_streaming_stats` adds `regions_resident`, `regions_undrawn` and
  `uploads`; `slots_used` counts drawn regions. `get_region_id` is the GPU layer (−1 when
  not drawn); use `has_region` for residency.
- **Files:** `src/terrain_3d_data.{h,cpp}`, `src/terrain_3d_instancer.cpp` (commit adfe38d).
- **Test:** `project/tests/test_window_slots.gd`: data-only regions outside the window
  answer height and normal; an edit made while data only reaches the GPU when the window
  arrives (readback when windowed); slots return when the window leaves; a full window
  leaves one region undrawn until an eviction hands it a slot; replacing a data-only
  region keeps it data only. `test_region_window.gd` checks at every window position that
  exactly the resident regions inside it hold slots; `test_slot_pool.gd` covers the full
  pool.
- **Upstream:** none; belongs with the window change (entry 4).
