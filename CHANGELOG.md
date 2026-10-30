# Changelog

All notable changes to this project will be documented in this file.

## [1.4.0] - 2026-10-30

### Added
- "Daily Challenge" in the menu, right after "New game": today's puzzle at
  your size and difficulty, the same grid for everyone playing it today.
  Needs game-common 1.7.0.

## [1.3.0] - 2026-10-30

### Changed
- Redesigned play screen: the board is larger, filling the room the controls
  leave, with a full-width action bar under the status line. The frame has
  extra padding, so a loop along the outer edge no longer reads as the frame.
- The status line reads "7×7 · Medium · Edges left: 14" and wraps in
  landscape instead of being cut off.
- The title-bar menu shows "Size: …", "Difficulty: …" and "Show solution" /
  "Hide solution" (was "Grid: …", "Diff: …" and a bare "Show" / "Hide"), like
  every other game.
- Once the puzzle is solved, the action bar shows "New game" in place of
  Check/Hint/Undo, so the next round no longer needs the menu. Showing the
  solution does not end the round, since it can be hidden again.

### Fixed
- Clue digits were sized from pixels and then scaled again for the screen's
  DPI, so they could run into the lines and crosses along the cell edges. They
  are now measured to stay clear of them.
- Using a hint wiped the saved game; it is now kept. When a hint completes
  the loop, the status shows the win message.

## [1.2.2] - 2026-10-07

### Fixed
- The Tools menu entry is translated again. `main.lua` took `_` from
  KOReader's `gettext`, which knows nothing of this plugin's strings, so the
  menu label stayed English while the game's own screen, which goes through
  `i18n`, was translated. `_` now comes from `i18n` here too.


## [1.2.1] - 2026-10-01

### Fixed
- Picks up game-common v1.5.0. Play statistics were recorded under a key no
  tool could match: `ReaderUI`/`FileManager:registerModule()` rewrite a plugin
  instance's `name` to `reader<id>` / `filemanager<id>` right after it is
  built, so this game's sessions were split across two rows and neither
  carried its plugin id. Rows written under the old keys are merged back on
  first read. The same release brings the `stopPlugin()` /
  `deletePluginSettings()` hooks KOReader 2026.07 calls when a plugin is
  deleted from the device (PR #15240).

  No change to this plugin's own code -- it inherits all of it from the
  shared library.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button. Two taps: the first names the segment that is about to give -- horizontal or vertical, since the two edge grids are independent -- the second draws it. Crossing an edge out is optional bookkeeping, so only missing segments are offered. A move that contradicts the solution is always
  reported before a fresh one is revealed.


## [1.1.10] - 2026-07-31

### Fixed
- `board_widget.lua` referenced Blitbuffer color constants that don't
  exist (COLOR_GRAY_A), which evaluated to `nil` and crashed the
  color-comparison in `paintTo()` as soon as the corresponding
  highlight was drawn. Now uses the correct constant name(s)
  (COLOR_GRAY).

## [1.1.7] - 2026-07-28

### Fixed
- Generated puzzles had no uniqueness verification at all — measured as
  low as 1 in 10 puzzles actually having a unique solution at the
  hardest size/difficulty. Added a uniqueness solver and reworked
  generation to verify each puzzle before accepting it. Every puzzle now
  ships with a guaranteed unique solution.
