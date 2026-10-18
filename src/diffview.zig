// The diff poof shows at its y/N/d prompt.
//
// The change list poof collected from the overlay upper dir *is* the scope: what
// this prints is exactly what poof would apply. Comparing the target directory
// with the stash instead - which is what `git diff --no-index <target> <stash>`
// used to do - swept in every unrelated difference in the directory, a
// repository's own uncommitted work among them, and made git (which poof
// otherwise never touches) a requirement for reading poof's own result.
//
// The text comparison comes from diffz, a diff-match-patch port. Its operations
// are character-level, so they get expanded to whole lines here: a line counts as
// unchanged only where the diff matches it exactly, line for line, and everything
// else is printed as a whole-line change. That is what turns a text diff into the
// unified diff below.

const std = @import("std");
const linux = std.os.linux;
const diffz = @import("diffz");

const sandbox = @import("sandbox.zig");
const output = @import("output.zig");

const allocator = sandbox.allocator;
const testing = std.testing;

// Colors are read through functions rather than bound to globals: output.init()
// decides whether they are in use, and it runs after this file's scope is loaded.
fn red() []const u8 {
    return output.col(output.Color.red);
}
fn green() []const u8 {
    return output.col(output.Color.green);
}
fn yellow() []const u8 {
    return output.col(output.Color.yellow);
}
fn dim() []const u8 {
    return output.col(output.Color.dim);
}
fn bold() []const u8 {
    return output.col(output.Color.bold);
}
fn reset() []const u8 {
    return output.col(output.Color.reset);
}

// ---------------------------------------------------------------------------
// The change list, shared with the overlay collection and apply code in main.zig.
// ---------------------------------------------------------------------------

pub const ChangeType = enum { added, edited, deleted };

pub const Change = struct {
    path: []const u8,
    change_type: ChangeType,
};

pub const ChangeList = struct {
    items: []Change,
    len: usize,

    pub fn append(self: *ChangeList, change: Change) void {
        if (self.len < self.items.len) {
            self.items[self.len] = change;
            self.len += 1;
        }
    }
};

pub const Limits = struct {
    /// Files at or above this size are reported rather than diffed.
    max_file_bytes: usize = 512 * 1024,
    /// Diff lines printed across the session before the output is cut short.
    max_lines: usize = 4000,
    /// Unchanged lines kept around each change.
    context: usize = 3,
};

// ---------------------------------------------------------------------------
// Output sink: one write syscall per buffer rather than per line.
// ---------------------------------------------------------------------------

const Sink = struct {
    buf: [16 * 1024]u8 = undefined,
    len: usize = 0,

    fn str(self: *Sink, s: []const u8) void {
        var rest = s;
        while (rest.len > 0) {
            if (self.len == self.buf.len) self.flush();
            const take = @min(rest.len, self.buf.len - self.len);
            @memcpy(self.buf[self.len .. self.len + take], rest[0..take]);
            self.len += take;
            rest = rest[take..];
        }
    }

    fn flush(self: *Sink) void {
        if (self.len == 0) return;
        output.writeOut(self.buf[0..self.len]);
        self.len = 0;
    }
};

// ---------------------------------------------------------------------------
// Reading one side of a change
// ---------------------------------------------------------------------------

const Side = union(enum) {
    absent,
    text: []const u8,
    symlink: []const u8,
    special,
    too_large,
    binary,
    unreadable,
};

fn statOf(path: []const u8) ?linux.Statx {
    const z = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(z);
    var sx: linux.Statx = undefined;
    const r = linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &sx);
    if (sandbox.errnoFromSyscall(r) != .SUCCESS) return null;
    return sx;
}

fn readLink(path: []const u8, buf: []u8) ?[]const u8 {
    const z = allocator.dupeSentinel(u8, path, 0) catch return null;
    defer allocator.free(z);
    const n = linux.readlink(z, buf.ptr, buf.len);
    if (sandbox.errnoFromSyscall(n) != .SUCCESS) return null;
    return buf[0..n];
}

fn looksBinary(text: []const u8) bool {
    const window = @min(text.len, 8000);
    return std.mem.indexOfScalar(u8, text[0..window], 0) != null;
}

/// Read a file whole, categorising anything that cannot be diffed as text.
fn loadSide(path: []const u8, limits: Limits) Side {
    const sx = statOf(path) orelse return .absent;
    const mode: u32 = sx.mode;

    if (linux.S.ISLNK(mode)) {
        var buf: [4096]u8 = undefined;
        const target = readLink(path, buf[0..]) orelse return .unreadable;
        return .{ .symlink = allocator.dupe(u8, target) catch return .unreadable };
    }
    if (!linux.S.ISREG(mode)) return .special;
    if (sx.size >= limits.max_file_bytes) return .too_large;

    const fd = sandbox.openForRead(path) catch return .unreadable;
    defer _ = linux.close(fd);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    while (bytes.items.len < limits.max_file_bytes) {
        const want = @min(@as(usize, 64 * 1024), limits.max_file_bytes - bytes.items.len);
        const chunk = allocator.alloc(u8, want) catch return .unreadable;
        defer allocator.free(chunk);
        const n = sandbox.readFd(fd, chunk) catch return .unreadable;
        bytes.appendSlice(allocator, chunk[0..n]) catch return .unreadable;
        if (n == 0) break;
    }

    const text = bytes.toOwnedSlice(allocator) catch return .unreadable;
    if (looksBinary(text)) return .binary;
    return .{ .text = text };
}

// ---------------------------------------------------------------------------
// Line tables: a line is the text up to and including its newline, so a file
// whose last line has no newline keeps that fact visible in its own line text.
// ---------------------------------------------------------------------------

const Lines = struct {
    text: []const u8,
    /// starts.len == count + 1; line i is text[starts[i]..starts[i + 1]].
    starts: std.ArrayList(usize),

    fn init(text: []const u8) Lines {
        var starts: std.ArrayList(usize) = .empty;
        starts.append(allocator, 0) catch return .{ .text = text, .starts = starts };
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\n') starts.append(allocator, i + 1) catch break;
        }
        if (starts.items[starts.items.len - 1] != text.len) {
            starts.append(allocator, text.len) catch {};
        }
        return .{ .text = text, .starts = starts };
    }

    fn deinit(self: *Lines) void {
        self.starts.deinit(allocator);
    }

    fn count(self: Lines) usize {
        if (self.starts.items.len == 0) return 0;
        return self.starts.items.len - 1;
    }

    fn at(self: Lines, i: usize) []const u8 {
        return self.text[self.starts.items[i]..self.starts.items[i + 1]];
    }
};

const Match = struct { old: usize, new: usize };

/// Pair up the lines the text diff left untouched. An operation counts only where
/// it starts exactly at a line boundary on both sides, and only whole lines inside
/// it are paired; a line only partly covered counts as changed, which is what
/// keeps the output a diff of lines rather than of line fragments.
fn collectMatches(old_lines: Lines, new_lines: Lines, matches: *std.ArrayList(Match)) !void {
    // poof deliberately runs without an Io instance of its own (see sandbox.zig:
    // an Io implementation's helper threads do not survive the sandbox's fork).
    // diffz reaches for io only to resolve a timeout, and the timeout here is
    // .none, so this single-threaded default is never dispatched through.
    const io = std.Io.Threaded.global_single_threaded.io();
    const dmp = diffz.initDefault(io, allocator);

    var ops = dmp.diff(old_lines.text, new_lines.text, false, .none) catch return error.OutOfMemory;
    defer diffz.deinitDiffList(allocator, &ops);

    const n_old = old_lines.count();
    const n_new = new_lines.count();
    const old_starts = old_lines.starts.items;
    const new_starts = new_lines.starts.items;

    var old_pos: usize = 0;
    var new_pos: usize = 0;
    var oi: usize = 0;
    var nj: usize = 0;

    for (ops.items) |op| {
        switch (op.operation) {
            .equal => {
                // Line boundaries inside an equal op sit at the same byte offsets
                // on both sides, because the op's text is the same on both sides.
                // So if the op starts partway into a line — character-level
                // diffs cut lines anywhere — the first newline in it realigns
                // both sides to a line boundary together.
                var off: usize = 0;
                while (oi + 1 < n_old and old_starts[oi + 1] <= old_pos) oi += 1;
                while (nj + 1 < n_new and new_starts[nj + 1] <= new_pos) nj += 1;
                if (!(oi < n_old and nj < n_new and
                    old_starts[oi] == old_pos and new_starts[nj] == new_pos))
                {
                    const nl = std.mem.indexOfScalar(u8, op.text, '\n');
                    if (nl == null) {
                        old_pos += op.text.len;
                        new_pos += op.text.len;
                        continue;
                    }
                    off = nl.? + 1;
                    while (oi + 1 < n_old and old_starts[oi + 1] <= old_pos + off) oi += 1;
                    while (nj + 1 < n_new and new_starts[nj + 1] <= new_pos + off) nj += 1;
                }
                if (oi >= n_old or nj >= n_new or
                    old_starts[oi] != old_pos + off or new_starts[nj] != new_pos + off)
                {
                    old_pos += op.text.len;
                    new_pos += op.text.len;
                    continue;
                }
                // Whole lines from that boundary to the end of the operation.
                var k: usize = 0;
                while (oi + k < n_old and nj + k < n_new and
                    old_starts[oi + k + 1] <= old_pos + op.text.len and
                    new_starts[nj + k + 1] <= new_pos + op.text.len)
                {
                    try matches.append(allocator, .{ .old = oi + k, .new = nj + k });
                    k += 1;
                }
                old_pos += op.text.len;
                new_pos += op.text.len;
            },
            .delete => old_pos += op.text.len,
            .insert => new_pos += op.text.len,
        }
    }
}

// ---------------------------------------------------------------------------
// Unified-diff hunks
// ---------------------------------------------------------------------------

const HunkWriter = struct {
    out: *std.ArrayList(u8),
    old_lines: Lines,
    new_lines: Lines,
    context: usize,
    max_lines: usize,
    /// Equal lines held back: they are the trailing context of the hunk in
    /// progress, or the leading context of the next one.
    pending: usize = 0,
    open: bool = false,
    /// Offset in `out` where the open hunk's body begins, so its header can be
    /// written in front of it once the line counts are known.
    body_at: usize = 0,
    old_start: usize = 0,
    new_start: usize = 0,
    old_count: usize = 0,
    new_count: usize = 0,
    lines_written: usize = 0,
    over: bool = false,

    fn put(self: *HunkWriter, s: []const u8) void {
        self.out.appendSlice(allocator, s) catch {
            self.over = true;
        };
    }

    /// One diff line with its marker. A line with no trailing newline is flagged,
    /// as unified diffs do.
    fn putLine(self: *HunkWriter, color: []const u8, marker: []const u8, text: []const u8) void {
        if (self.lines_written >= self.max_lines) {
            self.over = true;
            return;
        }
        self.lines_written += 1;
        const no_eol = text.len == 0 or text[text.len - 1] != '\n';
        self.put(color);
        self.put(marker);
        self.put(if (no_eol) text else text[0 .. text.len - 1]);
        self.put(reset());
        self.put(if (no_eol) "\n\\ No newline at end of file\n" else "\n");
    }

    fn putContext(self: *HunkWriter, old_index: usize) void {
        self.putLine(dim(), " ", self.old_lines.at(old_index));
        self.old_count += 1;
        self.new_count += 1;
    }

    /// Start a hunk, spending any held-back equal lines as its leading context.
    fn begin(self: *HunkWriter, old_line: usize, new_line: usize) void {
        self.open = true;
        self.body_at = self.out.items.len;
        self.old_start = old_line -| self.pending;
        self.new_start = new_line -| self.pending;
        const lead = self.pending;
        self.pending = 0;
        self.old_count = 0;
        self.new_count = 0;
        var i: usize = 0;
        while (i < lead and !self.over) : (i += 1) {
            self.putContext(self.old_start + i);
        }
    }

    /// The held-back lines fall inside the hunk that is already open.
    fn absorbPending(self: *HunkWriter, old_line: usize) void {
        self.absorbPendingTo(old_line, self.pending);
    }

    /// Spend `take` of the held-back lines as context; the rest are dropped, which
    /// is how a hunk ends with at most `context` lines of trailing context.
    fn absorbPendingTo(self: *HunkWriter, old_line: usize, take: usize) void {
        const first = old_line - self.pending;
        var i: usize = 0;
        while (i < take and !self.over) : (i += 1) {
            self.putContext(first + i);
        }
        self.pending = 0;
    }

    /// One side of a hunk header, the way git writes it: the count is left out
    /// when it is one, and an empty range is numbered 0,0.
    fn rangeText(_: *HunkWriter, start: usize, count: usize) []const u8 {
        if (count == 0) return "0,0";
        if (count == 1) return std.fmt.allocPrint(allocator, "{d}", .{start + 1}) catch "0";
        return std.fmt.allocPrint(allocator, "{d},{d}", .{ start + 1, count }) catch "0";
    }

    /// Write "@@ -a,b +c,d @@" in front of the buffered body.
    fn close(self: *HunkWriter) void {
        if (!self.open) return;
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(allocator);
        head.print(allocator, "{s}@@ -{s} +{s} @@{s}\n", .{
            dim(),
            self.rangeText(self.old_start, self.old_count),
            self.rangeText(self.new_start, self.new_count),
            reset(),
        }) catch return;
        self.out.insertSlice(allocator, self.body_at, head.items) catch {
            self.over = true;
        };
        self.open = false;
    }
};

/// Render `old_text` against `new_text` as unified-diff hunks appended to `out`.
/// Returns the number of diff lines written: zero means the contents match.
fn renderHunks(out: *std.ArrayList(u8), old_text: []const u8, new_text: []const u8, limits: Limits) !usize {
    var old_lines = Lines.init(old_text);
    defer old_lines.deinit();
    var new_lines = Lines.init(new_text);
    defer new_lines.deinit();

    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(allocator);
    try collectMatches(old_lines, new_lines, &matches);

    var h = HunkWriter{
        .out = out,
        .old_lines = old_lines,
        .new_lines = new_lines,
        .context = limits.context,
        .max_lines = limits.max_lines,
    };

    var old_line: usize = 0;
    var new_line: usize = 0;
    var i: usize = 0;

    while (true) {
        // The gap up to the next run of matched lines, then that run. Past the end
        // of the match list the gap runs to the end of both files.
        var old_gap = old_lines.count() - old_line;
        var new_gap = new_lines.count() - new_line;
        var run_len: usize = 0;
        if (i < matches.items.len) {
            const m = matches.items[i];
            old_gap = m.old - old_line;
            new_gap = m.new - new_line;
            run_len = 1;
            while (i + run_len < matches.items.len and
                matches.items[i + run_len].old == m.old + run_len and
                matches.items[i + run_len].new == m.new + run_len)
            {
                run_len += 1;
            }
        }

        if (old_gap > 0) {
            if (h.open) h.absorbPending(old_line) else h.begin(old_line, new_line);
            var k: usize = 0;
            while (k < old_gap and !h.over) : (k += 1) {
                h.putLine(red(), "-", h.old_lines.at(old_line + k));
                h.old_count += 1;
            }
            old_line += k;
        }
        if (new_gap > 0) {
            if (h.open) h.absorbPending(old_line) else h.begin(old_line, new_line);
            var k: usize = 0;
            while (k < new_gap and !h.over) : (k += 1) {
                h.putLine(green(), "+", h.new_lines.at(new_line + k));
                h.new_count += 1;
            }
            new_line += k;
        }

        if (run_len > 0) {
            if (h.open and run_len > 2 * h.context) {
                // Long enough to split the hunk: finish this one with its context
                // and hold the tail back as the next one's leading context.
                var k: usize = 0;
                while (k < h.context and !h.over) : (k += 1) {
                    h.putContext(old_line + k);
                }
                old_line += k;
                new_line += k;
                h.close();
                // The rest of the run is skipped, except its last `context` lines,
                // which are held back as the next hunk's leading context - and so
                // sit immediately before the cursor, like every pending line.
                old_line += run_len - k;
                new_line += run_len - k;
                h.pending = h.context;
            } else if (h.open) {
                h.pending += run_len;
                old_line += run_len;
                new_line += run_len;
            } else {
                // No hunk open: spend the run, but hold its tail back - those are
                // the leading context of whatever change comes next, and they sit
                // immediately before the cursor, as every pending line does.
                old_line += run_len;
                new_line += run_len;
                h.pending = @min(run_len, h.context);
            }
        }

        if (h.over or i >= matches.items.len) break;
        i += run_len;
    }

    // Trailing context, then whatever is still open.
    if (h.open) {
        h.absorbPendingTo(old_line, @min(h.pending, h.context));
        h.close();
    }

    return h.lines_written;
}

// ---------------------------------------------------------------------------
// The whole change list, in order
// ---------------------------------------------------------------------------

fn note(sink: *Sink, text: []const u8) void {
    sink.str(dim());
    sink.str(text);
    sink.str(reset());
}

fn fileHeader(sink: *Sink, marker: []const u8, color: []const u8, path: []const u8) void {
    sink.str("\n");
    sink.str(color);
    sink.str(marker);
    sink.str(reset());
    sink.str(" ");
    sink.str(bold());
    sink.str(path);
    sink.str(reset());
    sink.str("\n");
}

/// Print a unified diff covering exactly the changes in `changes`.
/// `changes_root` is the stash path holding the new side of each change;
/// `target_root` is the directory the changes would be applied to.
pub fn showChanges(changes: []const Change, changes_root: []const u8, target_root: []const u8, limits: Limits) void {
    var sink: Sink = .{};
    defer sink.flush();

    var shown: usize = 0;
    var undiffed: usize = 0;

    for (changes) |change| {
        if (shown >= limits.max_lines) break;

        const display = if (change.path.len > 0 and change.path[0] == '/')
            change.path[1..]
        else
            change.path;

        const marker: []const u8 = switch (change.change_type) {
            .added => "+",
            .edited => "~",
            .deleted => "-",
        };
        const color: []const u8 = switch (change.change_type) {
            .added => green(),
            .edited => yellow(),
            .deleted => red(),
        };

        // A directory the sandbox created: there is nothing inside it to diff.
        if (std.mem.endsWith(u8, change.path, "/")) {
            fileHeader(&sink, marker, color, display);
            note(&sink, "  new directory\n");
            shown += 1;
            continue;
        }

        const new_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ changes_root, change.path }) catch continue;
        const old_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ target_root, change.path }) catch continue;

        const new_side = if (change.change_type == .deleted) Side.absent else loadSide(new_path, limits);
        const old_side = if (change.change_type == .added) Side.absent else loadSide(old_path, limits);

        fileHeader(&sink, marker, color, display);

        // A symlink diffs as its own target, not as whatever it points at.
        if (old_side == .symlink or new_side == .symlink) {
            const from = switch (old_side) {
                .symlink => |t| t,
                else => null,
            };
            const to = switch (new_side) {
                .symlink => |t| t,
                else => null,
            };
            if (from != null and to != null) {
                if (std.mem.eql(u8, from.?, to.?)) {
                    note(&sink, "  link unchanged\n");
                } else {
                    sink.str(std.fmt.allocPrint(allocator, "{s}- {s}{s}\n", .{ red(), from.?, reset() }) catch "");
                    sink.str(std.fmt.allocPrint(allocator, "{s}+ {s}{s}\n", .{ green(), to.?, reset() }) catch "");
                    shown += 2;
                }
            } else if (to != null) {
                sink.str(std.fmt.allocPrint(allocator, "{s}+ {s}{s}\n", .{ green(), to.?, reset() }) catch "");
                shown += 1;
            } else if (from != null) {
                sink.str(std.fmt.allocPrint(allocator, "{s}- {s}{s}\n", .{ red(), from.?, reset() }) catch "");
                shown += 1;
            } else {
                note(&sink, "  cannot read link\n");
                undiffed += 1;
            }
            continue;
        }

        const blocked: ?[]const u8 = switch (change.change_type) {
            .added => switch (new_side) {
                .text => null,
                .binary => "binary file (diff not shown)\n",
                .too_large => "file too large to diff\n",
                .special => "not a regular file (diff not shown)\n",
                .symlink => "cannot read link\n",
                .unreadable, .absent => "cannot read file\n",
            },
            .deleted => switch (old_side) {
                .text => null,
                .binary => "binary file (diff not shown)\n",
                .too_large => "file too large to diff\n",
                .special => "not a regular file (diff not shown)\n",
                .symlink => "cannot read link\n",
                .unreadable, .absent => "cannot read file\n",
            },
            .edited => switch (old_side) {
                .text => switch (new_side) {
                    .text => null,
                    .binary => "becomes a binary file (diff not shown)\n",
                    .too_large => "file too large to diff\n",
                    .special, .unreadable, .absent, .symlink => "the new contents cannot be read\n",
                },
                .binary => "binary file (diff not shown)\n",
                .too_large => "file too large to diff\n",
                .special, .unreadable, .absent, .symlink => "the old contents cannot be read\n",
            },
        };

        if (blocked) |why| {
            note(&sink, std.fmt.allocPrint(allocator, "  {s}", .{why}) catch why);
            undiffed += 1;
            continue;
        }

        const old_text: []const u8 = switch (old_side) {
            .text => |t| t,
            else => "",
        };
        const new_text: []const u8 = switch (new_side) {
            .text => |t| t,
            else => "",
        };

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);

        const written = renderHunks(&body, old_text, new_text, .{
            .max_file_bytes = limits.max_file_bytes,
            .max_lines = limits.max_lines -| shown,
            .context = limits.context,
        }) catch {
            note(&sink, "  diff skipped (out of memory)\n");
            undiffed += 1;
            continue;
        };

        // The overlay records a file as modified whenever it is written, even when
        // the bytes come out the same; say so instead of printing nothing.
        if (written == 0) {
            note(&sink, "  contents unchanged (written again with the same bytes)\n");
            continue;
        }

        sink.str(body.items);
        shown += written;
    }

    if (shown >= limits.max_lines or undiffed > 0) {
        sink.str("\n");
    }
    if (shown >= limits.max_lines) {
        note(&sink, std.fmt.allocPrint(
            allocator,
            "diff truncated after {d} lines: the list above is the complete set of changes\n",
            .{limits.max_lines},
        ) catch "");
    }
    if (undiffed > 0) {
        note(&sink, std.fmt.allocPrint(
            allocator,
            "{d} file{s} above could not be diffed as text\n",
            .{ undiffed, if (undiffed == 1) "" else "s" },
        ) catch "");
    }
}

/// Render a diff with colors off, so the text can be compared exactly.
fn diffText(old_text: []const u8, new_text: []const u8) ![]const u8 {
    output.setColors(false);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    _ = try renderHunks(&out, old_text, new_text, .{});
    return out.toOwnedSlice(allocator);
}

test "one changed line in an unchanged file is one hunk" {
    const got = try diffText("L1\nL2\nL3\nL4\nL5\nL6\n", "L1\nL2\nL3X\nL4\nL5\nL6\n");
    defer allocator.free(got);
    // The diff-match-patch operations are character-level: the equal region after
    // the change starts partway into the old file's third line, and pairing those
    // trailing lines up by whole lines is what keeps the hunk down to one line
    // instead of "everything from the change to the end of the file".
    try testing.expectEqualStrings("@@ -1,6 +1,6 @@\n L1\n L2\n-L3\n+L3X\n L4\n L5\n L6\n", got);
}

test "a file with nothing in common shows no context" {
    const got = try diffText("a\nb\n", "x\ny\nz\n");
    defer allocator.free(got);
    try testing.expectEqualStrings("@@ -1,2 +1,3 @@\n-a\n-b\n+x\n+y\n+z\n", got);
}

test "two changes far apart become two hunks" {
    // Eight unchanged lines between the changes: more than twice the context, so
    // they become two hunks, each with three lines of context of its own.
    const got = try diffText(
        "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\n",
        "l1\nl2x\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11x\nl12\n",
    );
    defer allocator.free(got);
    try testing.expectEqualStrings(
        "@@ -1,5 +1,5 @@\n l1\n-l2\n+l2x\n l3\n l4\n l5\n" ++
            "@@ -8,5 +8,5 @@\n l8\n l9\n l10\n-l11\n+l11x\n l12\n",
        got,
    );
}

test "added lines at the end, and a file with no trailing newline" {
    const got = try diffText("a\nb\n", "a\nb\nc");
    defer allocator.free(got);
    try testing.expectEqualStrings("@@ -1,2 +1,3 @@\n a\n b\n+c\n\\ No newline at end of file\n", got);
}

test "adding to an empty side covers every line" {
    const added = try diffText("", "a\nb\n");
    defer allocator.free(added);
    try testing.expectEqualStrings("@@ -0,0 +1,2 @@\n+a\n+b\n", added);

    const removed = try diffText("a\nb\n", "");
    defer allocator.free(removed);
    try testing.expectEqualStrings("@@ -1,2 +0,0 @@\n-a\n-b\n", removed);
}

test "two edits in one line stay one hunk" {
    const got = try diffText("the quick brown fox\n", "the quick red fox jumped\n");
    defer allocator.free(got);
    try testing.expectEqualStrings("@@ -1 +1 @@\n-the quick brown fox\n+the quick red fox jumped\n", got);
}

test "identical text renders no hunk at all" {
    const got = try diffText("same\nlines\n", "same\nlines\n");
    defer allocator.free(got);
    try testing.expectEqualStrings("", got);
}
