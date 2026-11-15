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
- **Data queries do not depend on the window.** While streaming, `has_region`,
  `get_height`, `get_normal`, `get_pixel`, `get_control` and the CPU region blend answer
  from the resident regions by location, the same for every window position. Collision
  already read regions by location. `get_region_id` / `get_region_idp` are the GPU slot,
  which since entry 5 depends on the window (−1 outside it); use `has_region` for
  residency.
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
  each changed region recalculates its height range (mesher AABBs) and refreshes
  collision; drawn ones also re-upload. A region that changed while data only and then
  takes a slot does the same sync when it attaches, so the upload cannot hide a pending
  collision refresh. `set_height` (any height `set_pixel`) grows the region's height range
  at once.
- **Instancer:** meshes are built only for regions holding a slot, checked in
  `_update_mmi_by_region`, so global rebuilds (`update_mmis()`, hiding and showing the
  terrain) obey it too. Eviction destroys a region's meshes whether or not it held a slot.
- **Stats:** every upload (insert inside the window, replacement, window arrival, edit) is
  timed and counted in `uploads`; `upload_usec_mean` is per upload.
- **Why:** in co-op the host keeps physics ground around every remote player
  (`Management/Planning/terrain_streaming_multiplayer.md` in the game repository) but
  never draws it. With a slot per resident region, that ground cost about 13 MB of VRAM
  per region for nothing; six scattered players at 3×3 would need about 1.7 GB on the host.
- **API changes:** `get_streaming_stats` adds `regions_resident`, `regions_undrawn` and
  `uploads`; `slots_used` counts drawn regions. `get_region_id` is the GPU layer (−1 when
  not drawn); use `has_region` for residency.
- **Files:** `src/terrain_3d_data.{h,cpp}`, `src/terrain_3d_instancer.cpp` (commit adfe38d,
  review fixes in the commit after it).
- **Test:** `project/tests/test_window_slots.gd`: data-only regions outside the window
  answer height and normal; an edit made while data only reaches the GPU when the window
  arrives (readback when windowed); slots return when the window leaves; a full window
  leaves one region undrawn until an eviction hands it a slot; replacing a data-only
  region keeps it data only. `test_region_window.gd` checks at every window position that
  exactly the resident regions inside it hold slots; `test_slot_pool.gd` covers the full
  pool. `test_window_slots_sync.gd` (Codex review regressions): an image replaced while data
  only reaches collision and the height range after the window arrives; `set_height` raises
  the height range; instancer meshes exist only while drawn, through a global rebuild and
  eviction (counts when windowed); upload accounting.
- **Upstream:** none; belongs with the window change (entry 4).

### 6. Several dynamic collision targets

- **What:** dynamic collision can keep ground around several nodes at once.
  `Terrain3D.add_collision_target(node, radius_m)` registers a node (or changes its
  radius), `remove_collision_target(node)` and `clear_collision_targets()` drop them,
  `get_collision_targets()` lists them; the same calls exist on `Terrain3DCollision`
  (`add_target`, `remove_target`, `clear_targets`, `get_targets`, `get_target_radius`)
  plus `get_stats()`.
  - The radius is in **metres**, per target. Stock `collision_radius` is in vertices, so
    at 0.25 m spacing its 64 vertices are only 16 m. At least the four shapes around a
    target are kept, however small the radius.
  - Shapes stay on the stock shape grid (`collision_shape_size` vertices) and each target
    is snapped to it as stock snaps its one target, so the shapes change only when a
    target crosses a grid line. A cell is kept when its centre lies within a target's
    radius of that target's snapped position, the stock test.
  - The pool fills the union of the targets' circles. Shapes are created on demand, so
    overlapping targets share shapes and the pool is never sized by hand. Shapes no longer
    needed are disabled and reused; they are freed when the body is rebuilt.
  - A freed target is dropped on the next update. A target outside the tree keeps its
    entry but gets no shapes until it returns.
  - With no targets registered, collision behaves exactly as stock (one target:
    `collision_target`, else the clipmap target, else the camera; `collision_radius` in
    vertices). The first target added and the last removed rebuild the body, switching
    between the two.
  - While streaming, a changed region (insert, replacement, eviction, edit sync) is
    remembered; the flush refills only the shapes whose samples read it (their border row
    and column included) and retries needed cells that had no region. A stationary target
    therefore gains ground when its region streams in and loses it when it is evicted.
    While the world background blends (FLAT or NOISE), heights depend on whether the
    regions around a vertex are resident, so when a region arrives or leaves, shapes one
    region out refill too; new data for a resident region (replacement, edit sync) refills
    only its own shapes. The stock single-target refresh test widens by one region the
    same way.
  - Collision keeps following registered targets, or the stock `collision_target`, when
    Terrain3D finds no camera and no clipmap target. Stock stops physics processing then.
    The meshes then snap to the origin fallback. Processing resumes when a camera is set
    (stock only resumed for a clipmap target), when dynamic collision with targets is
    re-entered from another mode, and when a target is added or its radius changed.
  - Radii must be finite, above 0 and at most 4096 m.
  - Full collision modes ignore the targets.
- **Stats:** `Terrain3DCollision.get_stats()`: `targets`, `shapes_total`, `shapes_active`,
  `shapes_free`, `updates`, `fills`, `update_usec_last/max/mean` (target updates only).
- **Why:** in co-op each peer needs ground under its own player and under the barge, and
  the host under the barge wherever the host player walks
  (`Management/Planning/terrain_streaming_multiplayer.md` in the game repository).
  Stock follows one node, so a host player walking more than the radius from the barge
  leaves the host-simulated barge with no ground.
- **Limits:** shapes fill synchronously (entry 8 makes each fill much cheaper);
  `test_collision_targets_perf.gd` logs the cost.
- **C#:** the addon's wrappers carry the same calls (`Terrain3D.AddCollisionTarget` …,
  `Terrain3DCollision.AddTarget` …, `GetStats`), as entries 3 and 4 did for `Terrain3DData`.
- **Files:** `src/terrain_3d_collision.{h,cpp}`, `src/terrain_3d.{h,cpp}` (commit ae48bef,
  review fixes in 015e155); `project/addons/terrain_3d/csharp/Terrain3D.cs`,
  `Terrain3DCollision.cs`.
- **Test:** `project/tests/test_collision_targets.gd`: separate targets (shape count from
  the rule), overlapping targets (union, no double count), radius in metres at 0.25 m
  spacing, the stock target ignored while targets exist, teleport and shape reuse, a
  stationary target gaining a streamed region, losing it on eviction and getting the
  replacement, the border samples refilled when the neighbour arrives, a freed target, the
  last target removed (stock target again), bad input refused (null, zero, infinite, NaN,
  huge radius), collision following a target with no camera, and (windowed only, as the
  headless renderer has no material uniforms) a neighbour arriving under the world
  background blend refilling the shapes next to it.
  `project/tests/test_csharp_wrapper_names.gd` checks every method, property and signal
  name in the C# wrappers against the native classes (stock and fork names alike).
  `project/tests/test_collision_targets_perf.gd` logs fill, step, idle and region flush
  times for the barge plus six players at 0.25 m with 48 m radius and 8 m shapes.
- **Upstream:** none; a general feature that could be offered upstream with the window.

### 7. Addon ships Windows and Linux x86_64 only; version 1.1.0-barge.1

- **What:** `terrain.gdextension` lists only the Windows and Linux x86_64 libraries (debug
  and release), and `plugin.cfg` says version `1.1.0-barge.1`.
- **Why:** the fork builds only those two platforms (rules above). Entries for platforms we
  do not build would point Godot at stock libraries that lack our changes, or at none.
  The version tells a fork install from stock in the editor's plugin list.
- **Files:** `project/addons/terrain_3d/terrain.gdextension`, `project/addons/terrain_3d/plugin.cfg`
  (commit a56a1b9 held only this entry; the two files landed two commits after
  3e85e64).
- **Test:** the game's smoke run and full suite load the extension on Windows; the Linux
  laptop loads it with the Linux build.
- **Upstream:** none (game packaging). Bump the `-barge.N` suffix with each install that
  changes behaviour.

### 8. Collision shapes filled from the region maps in blocks

- **What:** `Terrain3DData::get_modified_heights(vgrid, size, out)` returns
  `get_modified_height()` for a square block of vertices, and collision fills each shape
  (dynamic, several targets and full) from it. It gives the same heights, bit for bit:
  - the height and control maps are read through their image pointers (FORMAT_RF, checked;
    any other format falls back to the single read);
  - the material settings (world background, ground level, region blend) are read once
    per block, not by name for every vertex;
  - the world background blend runs per column and per row (its weights and sampled
    regions depend on x alone or on z alone), with the same float operations in the same
    order, and residency is looked up once per region around the block.
  `get_region_blend()` and the single `get_modified_height()` are unchanged.
- **Build flag:** bit-exactness needs the compiler not to fuse multiplies and adds
  differently in the two paths (a Codex probe reproduced mismatches with FMA contraction
  on, GCC `-mfma -ffp-contract=fast`, MSVC `/arch:AVX2 /fp:contract`). `SConstruct`
  therefore builds with `-ffp-contract=off` (GCC/Clang) and `/fp:precise` (MSVC, which
  contracts only with `/fp:contract`). This also keeps Windows and Linux builds on the
  same float results, which the cross-platform determinism gate needs.
- **Also:** `Terrain3DCollision::region_changed()` takes whether the region arrived or left.
  Only then do neighbouring shapes refill for the blend (entry 6); new data in a resident
  region refills only its own shapes.
- **Why:** collision fill cost the stock read path about 0.3 ms per 33 x 33 shape with the
  blend on (measured in the Codex review of entry 6: 1.27 s for the barge plus six
  players, 42 ms for one player stepping one shape), which would stall physics in co-op.
  `test_collision_targets_perf.gd` (Windows debug build, real renderer, blend on):
  - all seven targets (784 shapes): 1.27 s → 40 ms;
  - one target stepping one shape (12 shapes): 42 ms → 1.0 ms;
  - region under a target replaced (112 shapes, including about 20 ms for the region
    insert itself): 416 ms → 30 ms.
  What is left is mostly the physics server building each heightmap shape.
- **Files:** `src/terrain_3d_data.{h,cpp}`, `src/terrain_3d_collision.{h,cpp}`, `SConstruct`.
- **Test:** `project/tests/test_collision_fill.gd` reads every vertex of every placed shape
  back from the physics server and compares its bits (at the shape array's precision,
  signed zeros included; any NaN equals any NaN, since NaN only means "no ground") with
  `get_surface_height()`.
  It covers random heights with holes over regions with a gap and the blend on (windowed:
  it checks the blend changed vertices), a gap filled and a region replaced (region
  flushes), the blend off, material settings changed (entry 9), and the stock single
  target. `test_collision_targets_perf.gd` logs the times.
- **Upstream:** could be offered: it is a pure speed-up of the stock collision path.

### 9. Collision follows the material settings that change heights

- **What:** changing the world background, `ground_level` or `region_blend` on the
  material refreshes collision: dynamic collision refills its shapes, full collision
  rebuilds. The refresh is deferred and coalesced (one per frame while a slider is dragged).
- **Why:** these settings change `get_modified_height()`, which collision is built from.
  Stock left collision stale until something else rebuilt it, so data queries and physics
  disagreed. A Codex probe moved the ground level from −3 to 100 and found 5,949 of 6,358
  sampled vertices still at the old height.
- **Files:** `src/terrain_3d_material.{h,cpp}`, `src/terrain_3d_collision.{h,cpp}`.
- **Test:** `project/tests/test_collision_fill.gd` (windowed: the headless renderer has no
  material uniforms) changes the ground level and blend, then compares every collision
  vertex with the data.
- **Upstream:** could be offered (a stock bug).
