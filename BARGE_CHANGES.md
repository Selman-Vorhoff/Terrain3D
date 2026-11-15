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
