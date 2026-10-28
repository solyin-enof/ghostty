# Proportional Ghostty — todo

Design: `docs/plans/2026-10-12-proportional-layout-design.md`

## Setup
- [x] Branch `proportional` off upstream/main (1e9e14a)
- [x] Zig 0.16.0 in `.tools/` (git-excluded); Metal Toolchain installed
- [x] Baseline builds: `zig build -Demit-macos-app=false`, then the app via
      `cd macos && env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT=$PWD/build build`

## Milestone 1 — text
- [x] `src/renderer/proportional.zig` + fixture tests (11, mutation-checked)
- [x] `x_advance` on `font.shape.Cell`, filled by CoreText + HarfBuzz shapers
- [x] Config flag `font-proportional-layout` (default off)
- [x] Renderer: measure rows, run layout, offset glyphs/decorations/cursor
- [x] Alternate-screen gate (`state.screen == .primary`); checked live with `less`
- [x] Screenshots: ls -ln, git status (en + fr), df, ps, prose — flag on vs off
- [ ] Not yet checked live: a real shell with OSC 133 prompts, resize,
      scrollback scrolling, wide/CJK and emoji on the primary screen

Run the demo: `macos/build/Debug/Ghostty.app/Contents/MacOS/ghostty
--config-default-files=false --config-file=<conf>` with `font-family = Helvetica
Neue` and `font-proportional-layout = true`.

## Milestone 2 — backgrounds, selection highlight, block cursor
- [x] `cell_x` GPU buffer + `proportional` uniform; background shader per-row lookup
- [x] Stretch cursor (block/hollow/underline) and underline/strike/overline sprites
      to their cells, 3-slice so borders keep thickness, exact edges so no gaps
- [x] Screenshots: SGR backgrounds, reverse video, decorations, hollow cursor on `i`
- [ ] Selection highlight not exercised live (same per-cell bg path; driving a
      selection needs mouse mapping from milestone 3 or AppleScript permission)
- [ ] OpenGL/GLSL not updated; Linux cross-build fails in upstream egl.zig, so the
      generic code wasn't compile-checked against OpenGL

## Fixes from trying it
- [x] Columns jumped while scrolling (`ls` in ~): lay out 128 rows of overscan
      above/below the viewport; verified with a table whose widest name is
      scrolled off

- [x] `top` looked letter-spaced (alternate screen kept the grid): layout now
      runs on both screens
- [x] vim tore prose in coupled rows: identical-prefix, edge-only links,
      coverage, natural unaligned gaps; `top` column gap + flush-right clock
- [x] Lines wrapped at ~60% of the window: with the flag, cells are sized by
      "0" (FaceMetrics.zero_width, CoreText + FreeType); overflowing tables
      are squeezed to fit. Prose now wraps at ~80%.
- [x] Cursor-positioned (never-written-gap) words keep their grid column;
      aligned columns get a one-cell gap (top was tight with "0" cells)
- [x] htop header: meter bars (runs of `|`) keep one cell per character, and
      on the alternate screen jumped-to values keep their column; meters,
      values and Tasks/Load line up (Uptime within ~1 cell)
- [x] vim prose and code still tore under kerning: a chain aligns only if its
      gaps vary in blank cells (not pixels; replaces the 80% coverage rule),
      padding is judged after the identical prefix (vim's gutter), a lone
      skipped cell is a space, and cursor jumps need 2+ skipped cells
- [x] README section with screenshots (Avenir Next, Georgia, Verdana, Optima,
      Gill Sans) in `docs/proportional/`; fork published as solyin-enof/ghostty

## Milestone 3 — mouse (selection, reporting, links)
- [x] `proportional.gridX` + `SharedMap` (own lock), unit-tested
- [x] Renderer publishes viewport cell positions into `renderer.State.cell_x`
- [x] Surface maps every pointer position onto the grid on entry
      (`cursorPos()` for the 12 `getCursorPos()` calls, `cursorPosCallback`),
      so cell lookup, selection thresholds, mouse reporting and links are unchanged
- [x] Live check of click/drag selection: confirmed working by the user
      (background click injection couldn't drive it)
- [ ] Reverse direction (grid -> pixels): IME rect, QuickLook origin (milestone 4)
## Milestone 4 — decoration widths, IME rect, polish
