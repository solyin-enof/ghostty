//! Proportional layout: decides where each cell of a terminal row is
//! drawn when the font is proportional, while keeping columns that
//! programs lined up with padding (ls, git status, ps, df) lined up.
//!
//! The terminal grid is untouched; programs still see uniform cells. This
//! only maps cells to pixel x positions. The algorithm, in short:
//!
//!   1. Split each row into words (runs of text cells).
//!   2. Adjacent rows "couple" when they share enough word edges (left or
//!      right column) to look like a table. Prose rarely does.
//!   3. In coupled rows, words that overlap one-to-one are linked. Linked
//!      words form chains; a chain aligns on whichever edge (left or right)
//!      most of its members share.
//!   4. Rows flow left to right. Padding between words collapses to at most
//!      one cell width, and chained words are pushed right to the chain's
//!      common edge. Iterate until nothing moves.
//!
//! See docs/plans/2026-10-12-proportional-layout-design.md.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Kind = enum(u2) {
    /// A visible glyph, including the spacer tail of a wide character
    /// and cells covered by a ligature (which have zero advance).
    text,

    /// A space that was written to the cell (U+0020).
    space,

    /// A cell that was never written: tabs, cursor movement, erase.
    /// These keep monospace geometry so that cursor-positioned output
    /// and trailing cursor positions stay sane.
    empty,
};

pub const Cell = struct {
    kind: Kind,

    /// Natural advance in pixels. Ignored for `empty` cells, which are
    /// always one cell wide.
    advance: f32 = 0,
};

pub const Row = struct {
    cells: []const Cell,

    /// False for rows that must never align with their neighbors, such
    /// as shell prompt and input rows.
    couple: bool = true,
};

/// Fraction of word edges two adjacent rows must share to be treated as
/// rows of the same table; see `coupled`. Measured on the test fixtures:
/// padded table rows share >= 0.5 of the shorter row's edges, a table row
/// without padding shares >= 0.83 of the longer row's, and prose (even
/// two hint lines that start with the same words) shares <= 0.5.
const couple_padded: f32 = 0.4;
const couple_unpadded: f32 = 0.65;

/// Lay out `rows` and write each cell's left x position into `out`, which
/// holds `cols + 1` entries per row; the last entry is the row's end.
/// Every row must have the same number of cells.
///
/// `cell_width` is the width of an `empty` cell and the widest gap that
/// padding between aligned words collapses to. If no advance is wider
/// than `cell_width`, no row ends past `cols * cell_width`.
pub fn layout(
    alloc: Allocator,
    rows: []const Row,
    cell_width: f32,
    out: []f32,
) Allocator.Error!void {
    if (rows.len == 0) return;
    const cols = rows[0].cells.len;
    const stride = cols + 1;
    assert(out.len == rows.len * stride);

    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Natural x of every cell, as if nothing were aligned.
    const nat = try arena.alloc(f32, out.len);
    for (rows, 0..) |row, y| {
        assert(row.cells.len == cols);
        const n = nat[y * stride ..][0..stride];
        n[0] = 0;
        for (row.cells, 0..) |cell, x| n[x + 1] = n[x] + advance(cell, cell_width);
    }

    // Words, in row order. Words in row y are
    // words[row_start[y]..row_start[y + 1]], sorted by column.
    var words: std.ArrayList(Word) = .empty;
    const row_start = try arena.alloc(u32, rows.len + 1);

    // A row is padded if some gap between two of its words is wider than
    // one space or was made by a tab or cursor movement. Prose isn't.
    const padded = try arena.alloc(bool, rows.len);
    for (rows, 0..) |row, y| {
        row_start[y] = @intCast(words.items.len);
        padded[y] = false;
        const n = nat[y * stride ..][0..stride];
        var x: usize = 0;
        var gap: usize = 0;
        var gap_empty = false;
        while (x < cols) {
            if (row.cells[x].kind != .text) {
                gap += 1;
                gap_empty = gap_empty or row.cells[x].kind == .empty;
                x += 1;
                continue;
            }
            const after_padding = gap >= 2 or gap_empty;
            if (words.items.len > row_start[y] and after_padding) padded[y] = true;
            gap = 0;
            gap_empty = false;

            const l = x;
            while (x < cols and row.cells[x].kind == .text) x += 1;
            try words.append(arena, .{
                .l = @intCast(l),
                .r = @intCast(x - 1),
                .width = n[x] - n[l],
                .after_padding = after_padding,
            });
        }

        // A last word padded out to the right edge (a clock, a right
        // prompt, a status line) stays at the right edge.
        if (words.items.len > row_start[y] + 1) {
            const last = &words.items[words.items.len - 1];
            last.flush_right = last.after_padding and cols - 1 - last.r <= 2;
        }
    }
    row_start[rows.len] = @intCast(words.items.len);
    const ws = words.items;

    // Link words across coupled rows into chains (union-find).
    // Runs of coupled rows form tables; `table[y]` numbers them.
    const parent = try arena.alloc(u32, ws.len);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    const table = try arena.alloc(u32, rows.len);
    table[0] = 0;
    for (0..rows.len -| 1) |y| {
        table[y + 1] = table[y] + 1;
        if (!rows[y].couple or !rows[y + 1].couple) continue;
        const a = ws[row_start[y]..row_start[y + 1]];
        const b = ws[row_start[y + 1]..row_start[y + 2]];
        if (!coupled(a, b, padded[y] and padded[y + 1])) continue;
        table[y + 1] = table[y];
        for (a, 0..) |wa, ia| {
            const ib = pick(wa, b) orelse continue;
            if (pick(b[ib], a) != ia) continue;
            unite(parent, row_start[y] + @as(u32, @intCast(ia)), row_start[y + 1] + @as(u32, @intCast(ib)));
        }
    }
    for (0..ws.len) |i| ws[i].chain = find(parent, @intCast(i));
    try assignAlignment(arena, ws);

    // How each chain treats the gaps before its words. Padding that
    // differs from row to row is the program aligning a column: it
    // collapses to the chain's smallest gap (at most one cell), and a
    // column with padding keeps at least half a cell. When every row has
    // the same gap (indentation, a gutter repeated on every line) nothing
    // is being aligned and the gaps stay natural.
    const gap_min = try arena.alloc(f32, ws.len);
    const gap_max = try arena.alloc(f32, ws.len);
    const column = try arena.alloc(bool, ws.len);
    const members = try arena.alloc(u32, ws.len);
    const table_rows = try arena.alloc(u32, rows.len);
    @memset(gap_min, std.math.inf(f32));
    @memset(gap_max, 0);
    @memset(column, false);
    @memset(members, 0);
    @memset(table_rows, 0);
    for (0..rows.len) |y| {
        table_rows[table[y]] += 1;
        const n = nat[y * stride ..][0..stride];
        for (row_start[y]..row_start[y + 1]) |i| {
            const w = ws[i];
            if (w.alignment == .none) continue;
            members[w.chain] += 1;
            if (i == row_start[y]) continue;
            const gap = n[w.l] - n[ws[i - 1].r + 1];
            gap_min[w.chain] = @min(gap_min[w.chain], gap);
            gap_max[w.chain] = @max(gap_max[w.chain], gap);
            if (w.after_padding) column[w.chain] = true;
        }
    }

    // A chain whose words all follow the same gap has no padding doing
    // alignment work. It's a column only if it runs down (nearly) the
    // whole table, like GNU `ls -l` fields; otherwise it's free text that
    // happens to start in the same column, like the arguments of two
    // commands of the same length in `ps`, and aligning it tears it.
    for (0..rows.len) |y| {
        for (row_start[y]..row_start[y + 1]) |i| {
            const w = &ws[i];
            if (w.alignment == .none) continue;
            const uniform = gap_max[w.chain] - gap_min[w.chain] < 0.001;
            const coverage = @as(f32, @floatFromInt(members[w.chain])) /
                @as(f32, @floatFromInt(table_rows[table[y]]));
            if (uniform and coverage < 0.8) w.alignment = .none;
        }
    }

    // Solve: flow every row, pushing chained words to their chain's
    // common edge, until no chain edge moves. Edges only move right and
    // each pass settles at least one more level of chains, so this ends.
    const pos = try arena.alloc(f32, ws.len);
    const edge = try arena.alloc(f32, ws.len);
    const need = try arena.alloc(f32, ws.len);
    @memset(edge, 0);
    var pass: usize = 0;
    while (pass <= ws.len) : (pass += 1) {
        @memset(need, 0);
        for (0..rows.len) |y| {
            const n = nat[y * stride ..][0..stride];
            var prev_end: f32 = 0;
            var prev_r: ?u16 = null;
            for (row_start[y]..row_start[y + 1]) |i| {
                const w = ws[i];

                // Gaps before unaligned words, like code indentation, stay
                // natural; see above for aligned ones. (Every gap stays
                // within its cells' monospace width, so rows never get
                // wider.)
                var req = if (prev_r) |pr| gap: {
                    const natural = n[w.l] - n[pr + 1];
                    const c = w.chain;
                    if (w.alignment == .none or gap_max[c] - gap_min[c] < 0.001) {
                        break :gap prev_end + natural;
                    }
                    const collapsed = @min(natural, gap_min[c], cell_width);
                    break :gap prev_end + if (column[c])
                        @max(collapsed, cell_width / 2)
                    else
                        collapsed;
                } else n[w.l];
                if (w.flush_right and w.alignment != .left) {
                    const grid_end = @as(f32, @floatFromInt(w.r + 1)) * cell_width;
                    req = @max(req, grid_end - w.width);
                }

                pos[i] = switch (w.alignment) {
                    .none => req,
                    .left => left: {
                        need[w.chain] = @max(need[w.chain], req);
                        break :left @max(req, edge[w.chain]);
                    },
                    .right => right: {
                        need[w.chain] = @max(need[w.chain], req + w.width);
                        break :right @max(req, edge[w.chain] - w.width);
                    },
                };
                prev_end = pos[i] + w.width;
                prev_r = w.r;
            }
        }

        var moved = false;
        for (need, edge) |nd, *e| if (nd > e.*) {
            e.* = nd;
            moved = true;
        };
        if (!moved) break;
    }

    // Write cell positions.
    for (rows, 0..) |row, y| {
        const n = nat[y * stride ..][0..stride];
        const o = out[y * stride ..][0..stride];
        var x: usize = 0;
        var cur: f32 = 0;
        for (row_start[y]..row_start[y + 1]) |i| {
            const w = ws[i];

            // Blank cells before a word continue naturally from the
            // previous word but never pass the word itself.
            while (x < w.l) : (x += 1) {
                o[x] = @min(cur, pos[i]);
                cur += advance(row.cells[x], cell_width);
            }

            // Cells inside a word keep their natural offsets.
            while (x <= w.r) : (x += 1) o[x] = pos[i] + (n[x] - n[w.l]);
            cur = pos[i] + w.width;
        }
        while (x < cols) : (x += 1) {
            o[x] = cur;
            cur += advance(row.cells[x], cell_width);
        }
        o[cols] = cur;
    }

    // Cells can be narrower than the widest glyphs (a proportional font's
    // cells are sized by "0"), so a row can end past the grid. Squeeze
    // every row of such a row's table by the same factor so it fits and
    // its columns stay aligned. Then fit the never-written cells after
    // each row's text into what's left, so the cursor stays on screen.
    const limit = @as(f32, @floatFromInt(cols)) * cell_width;
    const squeeze = try arena.alloc(f32, rows.len);
    @memset(squeeze, 1);
    for (0..rows.len) |y| {
        if (row_start[y] == row_start[y + 1]) continue;
        const last = row_start[y + 1] - 1;
        const end = pos[last] + ws[last].width;
        if (end > limit) squeeze[table[y]] = @min(squeeze[table[y]], limit / end);
    }
    for (0..rows.len) |y| {
        const o = out[y * stride ..][0..stride];
        const f = squeeze[table[y]];
        if (f < 1) for (o) |*v| {
            v.* *= f;
        };
        if (o[cols] <= limit) continue;
        const after: usize = if (row_start[y] == row_start[y + 1]) 0 else ws[row_start[y + 1] - 1].r + 1;
        const end = o[after];
        if (end >= limit) continue;
        const k = (limit - end) / (o[cols] - end);
        for (o[after..]) |*v| v.* = end + (v.* - end) * k;
    }
}

/// Map `x`, in pixels from the left edge of a row whose cell edges are
/// `xs` (`cols + 1` entries, as written by `layout`), to the matching x on
/// a grid of uniform `cell_width` cells: same cell, same fraction across
/// it. Pointer handling (cell lookup, selection thresholds, mouse
/// reporting) can then keep assuming a uniform grid. Positions left of the
/// row are unchanged; past the row's end they continue at one pixel per
/// pixel after the last cell.
pub fn gridX(xs: []const f32, x: f64, cell_width: f64) f64 {
    assert(xs.len >= 2);
    const cols = xs.len - 1;
    if (x < 0) return x;
    const end: f64 = xs[cols];
    if (x >= end) return @as(f64, @floatFromInt(cols)) * cell_width + (x - end);

    // Last cell starting at or before x; zero-width cells are skipped.
    var lo: usize = 0;
    var hi: usize = cols - 1;
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (xs[mid] <= x) lo = mid else hi = mid - 1;
    }
    const left: f64 = xs[lo];
    const width: f64 = xs[lo + 1] - left;
    const frac = if (width > 0) (x - left) / width else 0;
    return (@as(f64, @floatFromInt(lo)) + frac) * cell_width;
}

/// The cell positions of the last drawn frame, shared from the renderer
/// (which writes them) to the surface (which maps pointer positions with
/// them). It has its own lock, separate from the terminal's. Empty when
/// proportional layout isn't in use.
pub const SharedMap = struct {
    mutex: std.Io.Mutex = .init,
    xs: std.ArrayList(f32) = .empty,
    cols: usize = 0,

    pub fn deinit(self: *SharedMap, alloc: Allocator) void {
        self.xs.deinit(alloc);
    }

    /// Replace the map with `xs`: `cols + 1` entries per viewport row, or
    /// empty to turn mapping off.
    pub fn publish(
        self: *SharedMap,
        alloc: Allocator,
        io: std.Io,
        xs: []const f32,
        cols: usize,
    ) Allocator.Error!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.xs.clearRetainingCapacity();
        try self.xs.appendSlice(alloc, xs);
        self.cols = cols;
    }

    /// `gridX` for viewport `row`, or `x` unchanged if there's no map.
    pub fn toGrid(self: *SharedMap, io: std.Io, row: usize, x: f64, cell_width: f64) f64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stride = self.cols + 1;
        if (self.cols == 0 or (row + 1) * stride > self.xs.items.len) return x;
        return gridX(self.xs.items[row * stride ..][0..stride], x, cell_width);
    }
};

const Alignment = enum { none, left, right };

const Word = struct {
    /// First and last cell column, inclusive.
    l: u16,
    r: u16,

    /// Natural width in pixels.
    width: f32,

    /// The gap before this word (including leading indentation) is padding:
    /// two or more blank cells, or a tab or cursor jump.
    after_padding: bool = false,

    /// The row's last word, padded out to (nearly) the last column: it
    /// keeps its grid position at the right edge.
    flush_right: bool = false,

    /// Union-find root of this word's chain (an index into the words).
    chain: u32 = 0,

    alignment: Alignment = .none,
};

fn advance(cell: Cell, cell_width: f32) f32 {
    return switch (cell.kind) {
        .text, .space => cell.advance,
        .empty => cell_width,
    };
}

/// True if two adjacent rows share enough word edges to be one table.
///
/// Leading words that are identical in both rows (same columns and width:
/// an editor's line numbers, a comment marker, list numbering, repeated
/// permissions in `ls -l`) say nothing either way, so they're set aside
/// and only the rest of the rows is judged, except that identical words
/// after padding still count as shared columns. If one row has nothing left,
/// its words all match the other's and coupling is harmless. The same
/// goes for the next word starting in the same column right after the
/// prefix (the command after `ps`'s PID and STAT).
///
/// When both rows are padded, a share of the shorter rest's edges is
/// enough (a short last row of `ls -C`). Otherwise it takes a large share
/// of the longer one's: the widest row of a column has no padding (GNU
/// `ls -l`), but neither does prose, and a prose line can share several
/// edges with a short table row by coincidence. Failing that, rows couple
/// when one row's padding lines its words up with the other's. Padding
/// counts anywhere in the row: the identical part can hold a row's only
/// padded field (`ls -l` sizes).
fn coupled(a: []const Word, b: []const Word, both_padded: bool) bool {
    if (a.len == 0 or b.len == 0) return false;
    var same: usize = 0;
    var same_columns: usize = 0;
    while (same < @min(a.len, b.len) and
        a[same].l == b[same].l and
        a[same].r == b[same].r and
        a[same].width == b[same].width) : (same += 1)
    {
        // An identical word after padding (not just indentation) is still
        // a padded column, like equal values in a `ps` column.
        if (same > 0 and a[same].after_padding and b[same].after_padding) same_columns += 1;
    }
    var ra = a[same..];
    var rb = b[same..];
    if (ra.len == 0 or rb.len == 0) return true;

    // Right after an identical prefix both rows' next words start in the
    // same column by construction; that isn't evidence either.
    if (same > 0 and ra[0].l == rb[0].l) {
        ra = ra[1..];
        rb = rb[1..];
        if (ra.len == 0 or rb.len == 0) return true;
    }

    if (paddedOnto(ra, rb) or paddedOnto(rb, ra)) return true;
    const shared: f32 = @floatFromInt(sharedEdges(ra, rb, "l") + sharedEdges(ra, rb, "r") + 2 * same_columns);
    const words: f32 = @floatFromInt(2 * (same_columns + if (both_padded) @min(ra.len, rb.len) else @max(ra.len, rb.len)));
    // One shared edge is too easily a coincidence, however short the rows.
    return shared >= 2 and shared >= words * if (both_padded) couple_padded else couple_unpadded;
}

/// True if `a` has at least two words after padding and every one of them
/// starts where a word of `b` starts: the padding is there to line up with
/// `b`, even when `b` has none of its own because it holds the widest
/// entries (French `git status`, whose labels end in a no-break space).
/// Only left edges count; a right edge matches prose too easily.
fn paddedOnto(a: []const Word, b: []const Word) bool {
    var count: usize = 0;
    for (a) |w| {
        if (!w.after_padding) continue;
        for (b) |o| {
            if (o.l == w.l) break;
        } else return false;
        count += 1;
    }
    return count >= 2;
}

/// Count columns where both rows have a word edge of the given side.
/// Words in a row don't overlap, so both lists are sorted on either edge.
fn sharedEdges(a: []const Word, b: []const Word, comptime side: []const u8) usize {
    var i: usize = 0;
    var j: usize = 0;
    var count: usize = 0;
    while (i < a.len and j < b.len) {
        const ea = @field(a[i], side);
        const eb = @field(b[j], side);
        if (ea == eb) {
            count += 1;
            i += 1;
            j += 1;
        } else if (ea < eb) i += 1 else j += 1;
    }
    return count;
}

/// The word in `others` that `w` corresponds to: the overlapping word that
/// shares its left edge, or else its right edge. Merely overlapping isn't
/// enough; columns line up on an edge, and linking words that only overlap
/// tears apart prose that happens to sit in coupled rows.
fn pick(w: Word, others: []const Word) ?usize {
    // First word ending at or after w starts.
    var lo: usize = 0;
    var hi: usize = others.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (others[mid].r < w.l) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < others.len and others[end].l <= w.r) end += 1;

    for (others[lo..end], lo..) |o, i| if (o.l == w.l) return i;
    for (others[lo..end], lo..) |o, i| if (o.r == w.r) return i;
    return null;
}

fn find(parent: []u32, i: u32) u32 {
    var x = i;
    while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
    }
    return x;
}

fn unite(parent: []u32, a: u32, b: u32) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra != rb) parent[@max(ra, rb)] = @min(ra, rb);
}

/// Give each chained word an alignment. A chain aligns on whichever edge
/// the most members share (left wins ties); members off that edge, like a
/// header wider than its column, flow naturally instead.
fn assignAlignment(arena: Allocator, ws: []Word) Allocator.Error!void {
    const order = try arena.alloc(u32, ws.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, ws, struct {
        fn lessThan(words: []Word, a: u32, b: u32) bool {
            return words[a].chain < words[b].chain;
        }
    }.lessThan);

    var start: usize = 0;
    while (start < order.len) {
        var end = start + 1;
        while (end < order.len and ws[order[end]].chain == ws[order[start]].chain) end += 1;
        defer start = end;

        const members = order[start..end];
        if (members.len < 2) continue;

        const l = mode(ws, members, "l");
        const r = mode(ws, members, "r");
        if (@max(l.count, r.count) < 2) continue;
        const side: Alignment, const col = if (l.count >= r.count)
            .{ .left, l.value }
        else
            .{ .right, r.value };
        for (members) |m| {
            const e = if (side == .left) ws[m].l else ws[m].r;
            if (e == col) ws[m].alignment = side;
        }
    }
}

/// Most common value of an edge among chain members. Chains are short
/// (one word per row at most), so quadratic is fine.
fn mode(ws: []const Word, members: []const u32, comptime side: []const u8) struct { value: u16, count: usize } {
    var best: u16 = 0;
    var best_count: usize = 0;
    for (members) |m| {
        const v = @field(ws[m], side);
        var count: usize = 0;
        for (members) |o| {
            if (@field(ws[o], side) == v) count += 1;
        }
        if (count > best_count) {
            best = v;
            best_count = count;
        }
    }
    return .{ .value = best, .count = best_count };
}

// ---------------------------------------------------------------------
// Tests
//
// Fixtures are real command output captured on macOS (uid/gid numeric).
// `~` marks a TAB, which a terminal turns into never-written cells up to
// the next multiple of 8. Metrics are fake and deliberately uneven so a
// test fails the moment alignment stops happening: 'i' is 3px, 'W' is
// 12px, a space is 3px, everything else is 7px, and a cell is 12px.

const testing = std.testing;
const test_cell_width: f32 = 12;

fn testAdvance(c: u21) f32 {
    return switch (c) {
        'i' => 3,
        'W' => 12,
        ' ' => 3,
        else => 7,
    };
}

const Fixture = struct {
    alloc: Allocator,
    /// Each row as the terminal would hold it, one codepoint per cell;
    /// 0 is a never-written cell.
    lines: [][]u21,
    cells: []Cell,
    rows: []Row,
    out: []f32,
    cols: usize,

    fn init(alloc: Allocator, text: []const u8) !Fixture {
        return initPadded(alloc, text, 4);
    }

    /// Like `init`, with `extra` never-written cells after the longest line.
    fn initPadded(alloc: Allocator, text: []const u8, extra: usize) !Fixture {
        var lines: std.ArrayList([]u21) = .empty;
        errdefer {
            for (lines.items) |l| alloc.free(l);
            lines.deinit(alloc);
        }
        var cols: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |src| {
            var line: std.ArrayList(u21) = .empty;
            errdefer line.deinit(alloc);
            var cps = (try std.unicode.Utf8View.init(src)).iterator();
            while (cps.nextCodepoint()) |c| {
                if (c == '~') {
                    try line.append(alloc, 0);
                    while (line.items.len % 8 != 0) try line.append(alloc, 0);
                } else try line.append(alloc, c);
            }
            cols = @max(cols, line.items.len);
            try lines.append(alloc, try line.toOwnedSlice(alloc));
        }
        cols += extra;

        const n = lines.items.len;
        const cells = try alloc.alloc(Cell, n * cols);
        errdefer alloc.free(cells);
        const rows = try alloc.alloc(Row, n);
        errdefer alloc.free(rows);
        for (lines.items, 0..) |line, y| {
            const rc = cells[y * cols ..][0..cols];
            for (rc, 0..) |*cell, col| {
                const c: u21 = if (col < line.len) line[col] else 0;
                cell.* = switch (c) {
                    0 => .{ .kind = .empty },
                    ' ' => .{ .kind = .space, .advance = testAdvance(' ') },
                    else => .{ .kind = .text, .advance = testAdvance(c) },
                };
            }
            rows[y] = .{ .cells = rc };
        }

        const out = try alloc.alloc(f32, n * (cols + 1));
        errdefer alloc.free(out);
        return .{
            .alloc = alloc,
            .lines = try lines.toOwnedSlice(alloc),
            .cells = cells,
            .rows = rows,
            .out = out,
            .cols = cols,
        };
    }

    fn deinit(self: *Fixture) void {
        for (self.lines) |l| self.alloc.free(l);
        self.alloc.free(self.lines);
        self.alloc.free(self.cells);
        self.alloc.free(self.rows);
        self.alloc.free(self.out);
    }

    fn run(self: *Fixture) !void {
        try self.runWith(test_cell_width);
    }

    fn runWith(self: *Fixture, cell_width: f32) !void {
        try layout(self.alloc, self.rows, cell_width, self.out);
    }

    fn x(self: *const Fixture, row: usize, col: usize) f32 {
        return self.out[row * (self.cols + 1) + col];
    }

    /// Column span of the first whitespace-delimited word equal to `word`.
    fn span(self: *const Fixture, row: usize, word: []const u8) [2]usize {
        const line = self.lines[row];
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == ' ' or line[i] == 0) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < line.len and line[i] != ' ' and line[i] != 0) i += 1;
            var cps = (std.unicode.Utf8View.init(word) catch unreachable).iterator();
            var j = start;
            while (cps.nextCodepoint()) |c| : (j += 1) {
                if (j == i or line[j] != c) break;
            } else if (j == i) return .{ start, i };
        }
        std.debug.panic("word '{s}' not in row {d}", .{ word, row });
    }

    fn startX(self: *const Fixture, row: usize, word: []const u8) f32 {
        return self.x(row, self.span(row, word)[0]);
    }

    fn endX(self: *const Fixture, row: usize, word: []const u8) f32 {
        return self.x(row, self.span(row, word)[1]);
    }

    /// Words given as .{ row, word } all start at the same x.
    fn expectLeft(self: *const Fixture, members: []const struct { usize, []const u8 }) !void {
        const want = self.startX(members[0][0], members[0][1]);
        for (members[1..]) |m| try testing.expectEqual(want, self.startX(m[0], m[1]));
    }

    /// Words given as .{ row, word } all end at the same x.
    fn expectRight(self: *const Fixture, members: []const struct { usize, []const u8 }) !void {
        const want = self.endX(members[0][0], members[0][1]);
        for (members[1..]) |m| try testing.expectEqual(want, self.endX(m[0], m[1]));
    }

    /// Row is laid out exactly as natural flow (nothing inserted).
    fn expectNatural(self: *const Fixture, row: usize) !void {
        var nat: f32 = 0;
        for (self.rows[row].cells, 0..) |cell, col| {
            try testing.expectApproxEqAbs(nat, self.x(row, col), 0.001);
            nat += advance(cell, test_cell_width);
        }
    }

    /// Positions never go backwards and no row ends past its monospace end.
    fn expectInvariants(self: *const Fixture) !void {
        try self.expectInvariantsWith(test_cell_width);
    }

    fn expectInvariantsWith(self: *const Fixture, cell_width: f32) !void {
        const limit = @as(f32, @floatFromInt(self.cols)) * cell_width;
        for (0..self.rows.len) |row| {
            for (0..self.cols) |col| try testing.expect(self.x(row, col) <= self.x(row, col + 1));
            try testing.expect(self.x(row, self.cols) <= limit + 0.001);
        }
    }
};

fn testFixture(text: []const u8) !Fixture {
    var f = try Fixture.init(testing.allocator, text);
    errdefer f.deinit();
    try f.run();
    try f.expectInvariants();
    return f;
}

test "ls -C (GNU, spaces and tabs): name columns line up" {
    var f = try testFixture(
        \\MOMMY.WAV  WWWWWW.md~iiii.txt     mmmmmmmmmm.c
        \\Makefile   a~~illicit.lit  my file.txt
        \\README.md  config.yaml~lil~     src
    );
    defer f.deinit();

    try f.expectLeft(&.{ .{ 0, "WWWWWW.md" }, .{ 1, "a" }, .{ 2, "config.yaml" } });
    try f.expectLeft(&.{ .{ 0, "iiii.txt" }, .{ 1, "illicit.lit" }, .{ 2, "lil" } });
    // "my file.txt" overlaps the name above it twice; it still links by
    // its left edge, so the whole column lines up.
    try f.expectLeft(&.{ .{ 0, "mmmmmmmmmm.c" }, .{ 1, "my" }, .{ 2, "src" } });
    // The space inside the filename stays a plain space.
    try testing.expectApproxEqAbs(
        f.endX(1, "my") + testAdvance(' '),
        f.startX(1, "file.txt"),
        0.001,
    );
}

test "ls -C (BSD, tabs only): name columns line up" {
    var f = try testFixture(
        \\MOMMY.WAV~a~~lil
        \\Makefile~config.yaml~mmmmmmmmmm.c
        \\README.md~iiii.txt~my file.txt
        \\WWWWWW.md~illicit.lit~src
    );
    defer f.deinit();

    try f.expectLeft(&.{ .{ 0, "a" }, .{ 1, "config.yaml" }, .{ 2, "iiii.txt" }, .{ 3, "illicit.lit" } });
    try f.expectLeft(&.{ .{ 0, "lil" }, .{ 1, "mmmmmmmmmm.c" }, .{ 2, "my" }, .{ 3, "src" } });
    // Tab padding collapses to a one-cell gap after the widest name
    // instead of keeping the tab's monospace width.
    const widest = @max(
        @max(f.endX(0, "MOMMY.WAV"), f.endX(1, "Makefile")),
        @max(f.endX(2, "README.md"), f.endX(3, "WWWWWW.md")),
    );
    try testing.expectApproxEqAbs(widest + test_cell_width, f.startX(0, "a"), 0.001);
}

test "ls -l (BSD): left and right aligned fields" {
    var f = try testFixture(
        \\total 112
        \\-rw-r--r--  1 502  0      0 Oct 12 03:38 MOMMY.WAV
        \\-rw-r--r--  1 502  0    912 Oct 12 04:18 Makefile
        \\-rw-r--r--  1 502  0      0 Oct  2  2025 README.md
        \\-rw-r--r--  1 502  0  48213 Oct 12 04:18 WWWWWW.md
        \\-rw-r--r--  1 502  0      0 Mar  5  2026 illicit.lit
        \\-rw-r--r--  1 502  0      0 Oct 12 03:38 mmmmmmmmmm.c
        \\-rw-r--r--  1 502  0      0 Oct 12 04:18 my file.txt
        \\drwxr-xr-x  2 502  0     64 Oct 12 04:18 src
    );
    defer f.deinit();

    try f.expectNatural(0); // "total" shares too little with the table
    try f.expectLeft(&.{ .{ 1, "502" }, .{ 4, "502" }, .{ 8, "502" } });
    try f.expectRight(&.{ .{ 2, "912" }, .{ 4, "48213" }, .{ 8, "64" } });
    try f.expectLeft(&.{ .{ 1, "Oct" }, .{ 5, "Mar" }, .{ 8, "Oct" } });
    try f.expectRight(&.{ .{ 1, "12" }, .{ 3, "2" }, .{ 5, "5" } });
    try f.expectRight(&.{ .{ 1, "03:38" }, .{ 3, "2025" }, .{ 5, "2026" } });
    try f.expectLeft(&.{
        .{ 1, "MOMMY.WAV" }, .{ 2, "Makefile" },    .{ 3, "README.md" },
        .{ 4, "WWWWWW.md" }, .{ 5, "illicit.lit" }, .{ 6, "mmmmmmmmmm.c" },
        .{ 7, "my" },        .{ 8, "src" },
    });
}

test "ls -l (GNU, single spaces): fields still align" {
    var f = try testFixture(
        \\-rw-r--r-- 1 502 0     0 Oct 12 03:38 MOMMY.WAV
        \\-rw-r--r-- 1 502 0   912 Oct 12 04:18 Makefile
        \\-rw-r--r-- 1 502 0     0 Oct  2  2025 README.md
        \\-rw-r--r-- 1 502 0 48213 Oct 12 04:18 WWWWWW.md
        \\drwxr-xr-x 2 502 0    64 Oct 12 04:18 src
    );
    defer f.deinit();

    // Permissions differ in glyph width ('d', 'x' vs '-'); everything
    // after them must still line up.
    try f.expectRight(&.{ .{ 0, "1" }, .{ 4, "2" } });
    try f.expectRight(&.{ .{ 1, "912" }, .{ 3, "48213" }, .{ 4, "64" } });
    try f.expectRight(&.{ .{ 0, "03:38" }, .{ 2, "2025" } });
    try f.expectLeft(&.{
        .{ 0, "MOMMY.WAV" }, .{ 1, "Makefile" }, .{ 2, "README.md" },
        .{ 3, "WWWWWW.md" }, .{ 4, "src" },
    });
}

test "git status: file names line up, hints stay prose" {
    var f = try testFixture(
        \\On branch main
        \\Changes to be committed:
        \\  (use "git restore --staged <file>..." to unstage)
        \\~new file:   new.txt
        \\~deleted:    wide_module_name.zig
        \\
        \\Changes not staged for commit:
        \\  (use "git add <file>..." to update what will be committed)
        \\  (use "git restore <file>..." to discard changes in working directory)
        \\~modified:   Makefile
        \\~modified:   alpha.c
    );
    defer f.deinit();

    try f.expectLeft(&.{ .{ 3, "new.txt" }, .{ 4, "wide_module_name.zig" } });
    try f.expectLeft(&.{ .{ 9, "Makefile" }, .{ 10, "alpha.c" } });
    for ([_]usize{ 0, 1, 2, 6, 7, 8 }) |row| try f.expectNatural(row);
}

test "git status in French: padding lines up with an unpadded row" {
    // French git ends each label with a no-break space and a colon. The
    // longest label leaves its row with no padding at all; the other
    // row's padding still lines its file name up with it.
    var f = try testFixture("Modifications qui seront valid\u{e9}es :\n" ++
        "  (utilisez \"git restore --staged <fichier>...\" pour d\u{e9}sindexer)\n" ++
        "~nouveau fichier\u{a0}: new.txt\n" ++
        "~supprim\u{e9}\u{a0}:        wide_module_name.zig\n" ++
        "\n" ++
        "~modifi\u{e9}\u{a0}:         Makefile\n" ++
        "~modifi\u{e9}\u{a0}:         alpha.c");
    defer f.deinit();

    try f.expectLeft(&.{ .{ 2, "new.txt" }, .{ 3, "wide_module_name.zig" } });
    try f.expectLeft(&.{ .{ 5, "Makefile" }, .{ 6, "alpha.c" } });
    try f.expectNatural(0);
    try f.expectNatural(1);
}

test "df: numbers right-aligned under headers, header mismatch tolerated" {
    var f = try testFixture(
        \\Filesystem        Size    Used   Avail Capacity iused ifree %iused  Mounted on
        \\/dev/disk3s1s1   7.3Ti    17Gi   2.0Ti     1%    427k  4.3G    0%   /
        \\/dev/disk3s5     7.3Ti   5.2Ti   2.0Ti    72%     20M   22G    0%   /System/Volumes/Data
    );
    defer f.deinit();

    try f.expectRight(&.{ .{ 0, "Size" }, .{ 1, "7.3Ti" }, .{ 2, "7.3Ti" } });
    try f.expectRight(&.{ .{ 0, "Used" }, .{ 1, "17Gi" }, .{ 2, "5.2Ti" } });
    try f.expectRight(&.{ .{ 0, "Avail" }, .{ 1, "2.0Ti" }, .{ 2, "2.0Ti" } });
    // macOS df pads "Capacity" and "%iused" wider than their values; the
    // values still line up with each other.
    try f.expectRight(&.{ .{ 1, "1%" }, .{ 2, "72%" } });
    try f.expectRight(&.{ .{ 0, "iused" }, .{ 1, "427k" }, .{ 2, "20M" } });
    try f.expectRight(&.{ .{ 0, "ifree" }, .{ 1, "4.3G" }, .{ 2, "22G" } });
    try f.expectLeft(&.{ .{ 0, "Mounted" }, .{ 1, "/" }, .{ 2, "/System/Volumes/Data" } });
}

test "ps: mixed left and right columns" {
    var f = try testFixture(
        \\  PID STAT      TIME COMM
        \\    1 Ss    17:17.79 /sbin/launchd
    );
    defer f.deinit();

    try f.expectRight(&.{ .{ 0, "PID" }, .{ 1, "1" } });
    try f.expectLeft(&.{ .{ 0, "STAT" }, .{ 1, "Ss" } });
    try f.expectRight(&.{ .{ 0, "TIME" }, .{ 1, "17:17.79" } });
    try f.expectLeft(&.{ .{ 0, "COMM" }, .{ 1, "/sbin/launchd" } });
}

test "ps: command arguments stay attached to their command" {
    // PID, STAT and COMMAND are columns; the arguments after each command
    // are free text that only overlaps words in the next row. They must
    // stay one space after their command.
    var f = try testFixture(
        \\  347 Ss   /usr/sbin/systemstats --daemon
        \\  359 Ss   /usr/libexec/keybagd -t 15
        \\  384 Ss   /usr/sbin/securityd -i
        \\  399 Ss   /usr/libexec/usermanagerd -t 15
        \\  404 Ss   /usr/libexec/corebrightnessd --launchd
        \\  430 Ss   /usr/libexec/nsurlsessiond --privileged
        \\  435 Ss   /usr/libexec/biometrickitd --launchd
    );
    defer f.deinit();

    try f.expectLeft(&.{ .{ 0, "Ss" }, .{ 3, "Ss" }, .{ 6, "Ss" } });
    try f.expectLeft(&.{ .{ 0, "/usr/sbin/systemstats" }, .{ 1, "/usr/libexec/keybagd" } });
    const args = [_]struct { usize, []const u8, []const u8 }{
        .{ 0, "/usr/sbin/systemstats", "--daemon" },
        .{ 1, "/usr/libexec/keybagd", "-t" },
        .{ 2, "/usr/sbin/securityd", "-i" },
        .{ 3, "/usr/libexec/usermanagerd", "-t" },
        .{ 4, "/usr/libexec/corebrightnessd", "--launchd" },
        .{ 5, "/usr/libexec/nsurlsessiond", "--privileged" },
        .{ 6, "/usr/libexec/biometrickitd", "--launchd" },
    };
    for (args) |a| try testing.expectApproxEqAbs(
        f.endX(a[0], a[1]) + testAdvance(' '),
        f.startX(a[0], a[2]),
        0.001,
    );
}

test "ps with padded columns: arguments still aren't aligned" {
    // The padded RSS column makes these rows a real table, so they couple.
    // Arguments after commands of equal length start in the same column by
    // coincidence (nsurlsessiond, biometrickitd); aligning them would open
    // a hole after the narrower command.
    var f = try testFixture(
        \\  PID  %CPU    RSS COMMAND
        \\  347   0.0  54224 /usr/sbin/systemstats --daemon
        \\  359   0.0   6272 /usr/libexec/keybagd -t 15
        \\  384   0.0  15792 /usr/sbin/securityd -i
        \\  399   0.0   6352 /usr/libexec/usermanagerd -t 15
        \\  404   0.0  18272 /usr/libexec/corebrightnessd --launchd
        \\  430   0.0  21280 /usr/libexec/nsurlsessiond --privileged
        \\  435   0.0  13408 /usr/libexec/biometrickitd --launchd
    );
    defer f.deinit();

    try f.expectRight(&.{ .{ 0, "RSS" }, .{ 1, "54224" }, .{ 2, "6272" } });
    try f.expectLeft(&.{ .{ 0, "COMMAND" }, .{ 1, "/usr/sbin/systemstats" }, .{ 7, "/usr/libexec/biometrickitd" } });
    const args = [_]struct { usize, []const u8, []const u8 }{
        .{ 4, "/usr/libexec/usermanagerd", "-t" },
        .{ 5, "/usr/libexec/corebrightnessd", "--launchd" },
        .{ 6, "/usr/libexec/nsurlsessiond", "--privileged" },
        .{ 7, "/usr/libexec/biometrickitd", "--launchd" },
    };
    for (args) |a| try testing.expectApproxEqAbs(
        f.endX(a[0], a[1]) + testAdvance(' '),
        f.startX(a[0], a[2]),
        0.001,
    );
}

test "prose is never torn apart by coincidental alignment" {
    var f = try testFixture(
        \\The terminal grid is a fifty year old contract between programs
        \\and screens. Every character takes one cell, so a program can
        \\line up a table by counting characters and padding with spaces.
        \\A proportional font breaks that contract, unless the terminal
        \\can recover the intent behind the padding and honor it anyway.
    );
    defer f.deinit();

    for (0..f.rows.len) |row| try f.expectNatural(row);
}

test "vim: prose after line numbers and comment markers stays prose" {
    // Rows that share an editor's line-number gutter, a comment marker and
    // list numbering look alike up front; that says nothing about the
    // prose after it, which must not be pulled into columns.
    var f = try testFixture(
        \\  8 //!   1. Split each row into words (runs of text cells).
        \\  9 //!   2. Adjacent rows "couple" when they share enough word edges (left or
        \\ 10 //!      right column) to look like a table. Prose rarely does.
        \\ 11 //!   3. In coupled rows, words that overlap one-to-one are linked. Linked
        \\ 12 //!      words form chains; a chain aligns on whichever edge (left or right)
        \\ 13 //!      most of its members share.
        \\ 14 //!   4. Rows flow left to right. Padding between words collapses to at most
        \\ 15 //!      one cell width, and chained words are pushed right to the chain's
        \\ 16 //!      common edge. Iterate until nothing moves.
        \\ 17 //!
        \\ 23 pub const Kind = enum(u2) {
        \\ 24     /// A visible glyph, including the spacer tail of a wide character
        \\ 25     /// and cells covered by a ligature (which have zero advance).
        \\ 26     text,
    );
    defer f.deinit();

    for (0..f.rows.len) |row| try f.expectNatural(row);
}

test "top: aligned columns get a gap, the clock stays at the right edge" {
    var f = try Fixture.initPadded(testing.allocator,
        \\Processes: 1181 total, 6 running, 1175 sleeping, 10929 threads                             18:02:12
        \\
        \\PID    COMMAND          %CPU TIME     #TH MEM   STATE
        \\97120  EAUpdaterService 0.0  00:00.07 2   2832K sleeping
        \\96784  ThemeWidgetContr 0.0  00:01.33 3   15M   sleeping
        \\96770  Draggable        0.0  02:07.52 3   34M   sleeping
        \\94567  translationd     0.0  00:02.59 3   7777K sleeping
    , 0);
    defer f.deinit();
    try f.run();
    try f.expectInvariants();

    try f.expectLeft(&.{ .{ 2, "COMMAND" }, .{ 3, "EAUpdaterService" }, .{ 5, "Draggable" } });
    try f.expectLeft(&.{ .{ 2, "%CPU" }, .{ 3, "0.0" }, .{ 6, "0.0" } });
    try f.expectLeft(&.{ .{ 2, "TIME" }, .{ 4, "00:01.33" }, .{ 6, "00:02.59" } });

    // top separates columns with a single space; aligned columns still
    // get at least half a cell between them, even after the widest name.
    try testing.expect(f.startX(4, "0.0") - f.endX(4, "ThemeWidgetContr") >= test_cell_width / 2);

    // The clock was padded out to the last column, so it stays there.
    const grid_width = @as(f32, @floatFromInt(f.cols)) * test_cell_width;
    try testing.expectApproxEqAbs(grid_width, f.endX(0, "18:02:12"), 0.001);
}

test "rows wider than the grid are squeezed to fit, columns intact" {
    // Proportional fonts get cells sized by "0", narrower than the widest
    // glyphs, so a row of wide glyphs can end past the grid. Here a cell
    // is 7px and 'W' is 12px.
    var f = try Fixture.initPadded(testing.allocator,
        \\WWWWWWWW  a
        \\iiii      b
    , 0);
    defer f.deinit();
    try f.runWith(7);

    try f.expectInvariantsWith(7);
    try f.expectLeft(&.{ .{ 0, "a" }, .{ 1, "b" } });
    const limit = @as(f32, @floatFromInt(f.cols)) * 7;
    try testing.expectApproxEqAbs(limit, f.endX(0, "a"), 0.001);
}

test "rows marked not to couple are left alone" {
    var f = try Fixture.init(testing.allocator,
        \\MOMMY.WAV  WWWWWW.md
        \\Makefile   a
    );
    defer f.deinit();
    f.rows[1].couple = false;
    try f.run();

    try f.expectNatural(0);
    try f.expectNatural(1);
}

test "empty input" {
    try layout(testing.allocator, &.{}, test_cell_width, &.{});
}

test "gridX keeps the cell and the fraction across it" {
    // Cells 3, 7, 12, 0 (a wide char's spacer) and 8 pixels wide, on a
    // 12 pixel grid.
    const xs = [_]f32{ 0, 3, 10, 22, 22, 30 };
    const cw: f64 = 12;

    // A quarter of the way into the 7px cell is a quarter into grid cell 1:
    // selection decides whether to include a cell by this fraction.
    try testing.expectApproxEqAbs(@as(f64, 12 + 3), gridX(&xs, 3 + 1.75, cw), 0.001);
    try testing.expectEqual(@as(f64, 0), gridX(&xs, 0, cw));

    // The zero-width cell is never under the pointer.
    try testing.expectEqual(@as(f64, 4 * 12), gridX(&xs, 22, cw));

    // Past the end of the row and left of it.
    try testing.expectEqual(@as(f64, 5 * 12 + 5), gridX(&xs, 35, cw));
    try testing.expectEqual(@as(f64, -4), gridX(&xs, -4, cw));
}

test "gridX is the identity on a uniform grid" {
    const xs = [_]f32{ 0, 12, 24, 36 };
    for ([_]f64{ 0, 5.5, 12, 23.9, 30, 40 }) |x| {
        try testing.expectApproxEqAbs(x, gridX(&xs, x, 12), 0.001);
    }
}

test "SharedMap maps per row and passes through without a map" {
    var map: SharedMap = .{};
    defer map.deinit(testing.allocator);
    const io = testing.io;

    // No map yet: unchanged.
    try testing.expectEqual(@as(f64, 17), map.toGrid(io, 0, 17, 12));

    // Two rows of two cells: row 0 is narrow, row 1 is uniform.
    try map.publish(testing.allocator, io, &.{ 0, 4, 8, 0, 12, 24 }, 2);
    try testing.expectEqual(@as(f64, 18), map.toGrid(io, 0, 6, 12));
    try testing.expectEqual(@as(f64, 6), map.toGrid(io, 1, 6, 12));

    // Rows past the map pass through.
    try testing.expectEqual(@as(f64, 6), map.toGrid(io, 2, 6, 12));
}
