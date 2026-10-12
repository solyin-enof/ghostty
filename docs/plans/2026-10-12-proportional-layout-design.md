# Proportional-font layout for Ghostty (design)

Goal: render the primary screen in a proportional font while columns that
programs line up with spaces (ls -C, ls -l, git status, ps, df) still line up.
Nothing outside the renderer changes: programs still see a normal cell grid,
TIOCGWINSZ, cursor addressing, reflow. Only the cell -> pixel mapping changes.

## Scope

- Primary screen only. The alternate screen (vim, less, htop) keeps the
  normal uniform grid.
- Behind a config flag, default off. Off = byte-for-byte stock Ghostty.
- macOS / Metal / CoreText first. HarfBuzz gets advances too so Linux can follow.

## Pieces

1. **Natural advances from the shaper.** `font.shape.Cell` gains
   `x_advance: f32`. The CoreText and HarfBuzz shapers already compute it and
   discard it; we keep it. It rides along in the shaper cache for free.

2. **`src/renderer/proportional.zig`** — pure layout, no font/terminal deps.
   Input per row: cells of `{kind: text|space|empty, advance}` plus whether
   the row may couple (prompt/input rows may not). Output per row:
   `cols + 1` pixel x positions (left edge of every cell, plus row end).

3. **Renderer hook (`generic.zig`).** When the flag is on and the screen is
   primary: measure every row (shape runs with no cursor/selection breaks so
   advances don't jitter), run layout, store `x_map`, then build cells as
   usual but shift each glyph/decoration/cursor by `x_map[x] - x*cell_width`
   through the existing `bearings[0]`. No shader change for milestone 1.
   Alignment is a cross-row property, so in this mode any dirty row forces a
   full rebuild (shaping is cached, so this is cheap).

## Cell kinds and widths

- `text`: visible glyph; width = shaper advance (wide chars: full width on the
  first cell, 0 on the spacer tail; ligature continuations: 0).
- `space`: a written space (U+0020); width = shaper advance of the space.
- `empty`: never-written cell (codepoint 0: tabs, cursor jumps, erase);
  width = `cell_width`. Cursor-positioned output keeps monospace geometry, and
  trailing empties keep the cursor in sane places.

## Layout algorithm

**Words.** A row splits into words = maximal runs of `text` cells. Each word
has cell columns `[L, R]` and a natural pixel width.

**Natural flow.** Without alignment, word *i+1* starts at word *i*'s end plus
the natural width of the blank cells between them. The first word starts at
the natural width of the leading blanks (indentation is preserved).

**Coupling (is this pair of rows a table?).** A row is *padded* if some gap
between two of its words is 2+ blank cells or contains a never-written cell
(tab, cursor jump). Prose isn't. Adjacent rows *r*, *r+1* couple when both may
couple and they share enough word edges (an edge is shared when the same kind
of edge, left or right, sits at the same column in both rows):

- both padded: `shared >= 0.4 * 2 * min(words_r, words_r+1)` (a short last row
  of `ls -C` still couples);
- otherwise: `shared >= 0.65 * 2 * max(words_r, words_r+1)`. The widest row of
  a column has no padding (GNU `ls -l`), but neither does prose, and a prose
  line can share several edges with a short table row by coincidence.

Measured on the fixtures: padded table pairs share >= 0.5 of the shorter row's
edges, unpadded table rows >= 0.83 of the longer row's, prose <= 0.5.

**Links.** In a coupled pair, word *a* (row r) picks a word in row r+1: the
only word it overlaps, else the overlapping word with the same left edge, else
the one with the same right edge. *a* and *b* link when they pick each other.
(`mmmmmmmmmm.c` above `my file.txt` overlaps two words and picks `my` by its
left edge.)

**Chains.** Connected components of links. A chain aligns on whichever edge
the most members share (left wins ties, at least 2 members). Members off that
edge flow naturally: macOS `df` pads the `Capacity` header wider than its
values, and the values still right-align with each other.

**Solve.** Each row is flowed left to right. A word's required start is the
previous word's end plus `min(natural_gap, gap)` (`gap` defaults to
`cell_width`: single spaces stay single spaces, padding collapses to one
column gap). A left chain's start `X` is the max of its members' required
starts; a right chain's end is the max of members' required ends. Words only
move right, so iterate to a fixpoint (2-3 passes in practice).

**Cell positions.** Cells inside a word follow natural offsets from the word
start. Blank cells between words continue naturally from the previous word's
end, clamped to the next word's start. Trailing cells continue naturally.
Positions are monotonic within a row.

**No-overflow invariant.** Ghostty's `cell_width` is the max ASCII advance, so
every natural width is `<=` its cell count times `cell_width` and every gap is
`<=` its natural width. By induction every word ends at or before its
monospace end, so no row ends past `cols * cell_width`. (Breaks if
`adjust-cell-width` shrinks the cell; then we clip. Compression is future
work.)

## Milestones

1. Text: advances, `proportional.zig`, glyph/decoration/cursor offsets via
   bearings, config flag, alternate-screen gate. Verify with screenshots of
   `ls -C`, `ls -l`, `git status`, and a prose paragraph.
2. Backgrounds and selection highlight: pass `x_map` to the GPU; background
   shader looks up the cell per row. Cursor block via the same map.
3. Mouse: selection, mouse reporting, link hover map pixel -> cell through
   `x_map` (renderer thread builds it, app thread reads it: needs a handoff).
4. Decoration widths (underline length), IME rect, config polish.

Later: kitty images on the primary screen, overflow compression, streaming
stability (columns can jump while output arrives).

## Testing

`proportional.zig` unit tests use fixtures captured from real commands, with
fake metrics (`i`=3px, `W`=12px, others 7px, space 3px, cell 12px) so every
assertion fails if alignment breaks:

- aligned output (ls -C, ls -l, git status, ps): every member of a column
  starts (or, right-aligned, ends) at the same x;
- prose: no gap wider than the natural gap is ever inserted;
- invariants on all fixtures: x is monotonic per row, and no row ends past
  `cols * cell_width`.

Mutation-checked: disabling alignment fails all 7 alignment tests; forcing
every pair to couple fails the prose and git-status tests.

Rendering is verified by screenshots of the built app.
