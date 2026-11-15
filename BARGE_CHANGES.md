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
