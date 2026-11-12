# Changelog

All notable changes to this project will be documented in this file.

## [1.6.1] - 2026-11-12

### Changed
- Picks up game-common 1.16.0: games for two readers (new Two readers
  category) and the shared Start / Join dialog.

## [1.6.0] - 2026-11-05

### Changed
- The three levels now really differ, and no puzzle needs trial and error.
  Each puzzle is solved by a logic solver before you see it:
  - **Easy**: the basic rules alone (a number's count, two lines per dot)
    solve it.
  - **Medium**: also needs a few patterns (a 3 or a 1 in a corner, two 3s
    side by side, ...) or loop deductions.
  - **Hard**: fewer numbers (about 42–48 % of the cells, down from 65–70 %),
    and many such steps, including the inside/outside reasoning.
  Before, a level only set how many numbers were shown: Easy was solved by
  the basic rules alone, some Hard puzzles could only be finished by
  guessing, and a 20×20 Hard grid sometimes showed every number.
- Where the solver gets stuck, the generator shows the number there,
  instead of more numbers at random.
- Large grids show a progress bar while a puzzle is being built (only if
  it takes long enough to notice).
- Faster generation: the logic solver now runs without LuaJIT's compiler,
  which kept recompiling it for every new solver it made. Worst case over
  50 seeds on a desktop: 20×20 Hard ~50 ms → ~33 ms, 10×10 Hard ~40 ms →
  ~23 ms. Same puzzles for the same seed.
- The Daily Challenge puzzle changes once with this version.

## [1.5.3] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.5.2] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.5.1] - 2026-11-04

### Fixed
- Undo no longer crashes the game: the board's move history was stored
  under the same name as the Undo action, which hid it.

## [1.5.0] - 2026-11-04

### Changed
- Much faster puzzle generation: a 20×20 Hard grid took up to 11 s on a
  desktop (several minutes on an e-reader); every size now takes a few
  hundredths of a second at most. The uniqueness check follows the loop
  and rejects a loop that closes too early right away, instead of only
  checking for stray loops once every edge was decided. Same puzzles as
  before for the same seed.

## [1.4.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.4.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.4.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

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
