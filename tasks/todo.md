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
## Milestone 3 — mouse (selection, reporting, links)
## Milestone 4 — decoration widths, IME rect, polish
