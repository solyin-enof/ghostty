# Proportional Ghostty — todo

Design: `docs/plans/2026-10-12-proportional-layout-design.md`

## Setup
- [x] Branch `proportional` off upstream/main (1e9e14a)
- [x] Zig 0.16.0 in `.tools/` (git-excluded); Metal Toolchain installed
- [x] Baseline builds: `zig build -Demit-macos-app=false`, then the app via
      `cd macos && env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -configuration Debug SYMROOT=$PWD/build build`

## Milestone 1 — text
- [ ] `src/renderer/proportional.zig` + fixture tests (written first, failing)
- [ ] `x_advance` on `font.shape.Cell`, filled by CoreText + HarfBuzz shapers
- [ ] Config flag (default off)
- [ ] Renderer: measure rows, run layout, offset glyphs/decorations/cursor
- [ ] Alternate-screen gate
- [ ] Screenshots: ls -C, ls -l, git status, prose — flag on vs off

## Milestone 2 — backgrounds, selection highlight, block cursor
## Milestone 3 — mouse (selection, reporting, links)
## Milestone 4 — decoration widths, IME rect, polish
