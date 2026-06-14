# slitherlink.koplugin

A Slitherlink plugin for [KOReader](https://github.com/koreader/koreader).


## Screenshot

*(Screenshot to be added.)*

## Rules

Draw a single closed loop along grid edges. Each numbered cell indicates exactly how many of its four sides the loop crosses. The loop must be a single continuous, non-branching, non-crossing closed curve.

## Concept

Draw a single, closed loop along the grid edges so that each numbered cell has
exactly that many of its four edges used by the loop. Cells without a number
may have any number of loop edges. The loop must be a single connected circuit
with no branches or crossings.

## Features

- **Multiple grid sizes** — 5×5, 10×10, 15×15, 20×20
- **Three difficulty levels** — Easy, Medium, Hard
- **Edge states** — unknown, line (part of the loop), cross (confirmed not used)
- **Loop validation** — detects closed sub-loops before the puzzle is complete
- **Check** — highlights edges that contradict a numbered clue
- **Reveal solution** — shows the full solution
- **Undo** — step back through your moves
- **Auto-save** — game state saved and restored on next launch

## Controls

| Action | How |
|--------|-----|
| Draw an edge | Tap between two dots |
| Mark an edge as unused (cross) | Long-press between two dots |
| Toggle line / cross | Tap an already-drawn edge |
| Undo last move | Tap **Undo** |
| Check progress | Tap **Check** |
| New game | Tap **New game** |
| Change grid size | Tap **Grid** |
| Change difficulty | Tap **Diff** |
| Show rules | Tap **Rules** |

## Why e-ink friendly?

The grid is static between taps. Edge lines and crosses are simple glyphs
that render crisply at any e-ink resolution without any colour requirement.

## License

GPL-3.0
