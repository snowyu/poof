// The report: the list of changes one `poof apply` put onto the target, written
// out so it can be read back with `poof apply --from=<report>`.
//
// A report is text on purpose. `poof apply <stash> --report=<file>` records the
// apply; editing that file turns it into a plan - the paths poof printed can be
// widened into globs (`src/**/*.c`), trimmed down, or given `!pattern` exclusions -
// and `poof apply --from=<file>` replays exactly what survives the edit. The
// `@stash` line records which upper dir the changes came from, so the file knows
// where its own paths live; a positional stash always overrides it.
//
// Patterns match the path poof prints for a change (relative to the target, so a
// stash applied onto / prints `home/me/proj/x.c`), which is why a report is
// portable between a session's stash and any other copy of it. The matching is
// shell globbing: `*` stays inside one path segment, `**/` spans any number of
// directories, and `{a,b}` and `[a-z]` work as they do in a shell. Unlike a
// shell's own expansion a leading dot is not special: `src/*` covers
// `src/.hidden`, and `! **/*.log` excludes a `.build.log` too.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const sandbox = @import("sandbox.zig");
const diffview = @import("diffview.zig");
const zglob = @import("zglob");

const allocator = sandbox.allocator;

pub const ChangeType = diffview.ChangeType;
pub const Change = diffview.Change;

// A report is hand-editable text over paths; anything larger is a mistake or a
// hostile file, and poof reads it all into memory.
pub const max_report_bytes: usize = 4 * 1024 * 1024;

pub const Error = error{
    CannotRead,
    CannotWrite,
    TooLarge,
    OutOfMemory,
};

pub const Entry = struct {
    pattern: []const u8 = "",
    /// null matches any kind: a hand-written line is allowed to name only the path.
    kind: ?ChangeType = null,
    exclude: bool = false,
};

pub const Report = struct {
    /// The parsed text, which the pattern slices point into.
    text: []const u8 = "",
    stash: ?[]const u8 = null,
    target: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    entries: []Entry = &.{},
    /// Whether `text` is this report's own (read by `load`) rather than the
    /// caller's buffer (`parse` borrows the text it was handed).
    owns_text: bool = false,

    /// Free what `load` allocated. The pattern slices point into `text`, so the
    /// entries have to go first.
    pub fn deinit(self: *Report, alloc: std.mem.Allocator) void {
        alloc.free(self.entries);
        if (self.owns_text) alloc.free(self.text);
        self.* = .{};
    }
};

pub fn kindChar(kind: ChangeType) u8 {
    return switch (kind) {
        .added => '+',
        .edited => '~',
        .deleted => '-',
    };
}

fn kindOfChar(ch: u8) ?ChangeType {
    return switch (ch) {
        '+' => .added,
        '~' => .edited,
        '-' => .deleted,
        else => null,
    };
}

/// The form a path is matched and written in: no leading slash (the target is the
/// prefix, not part of the path), and no trailing slash (an empty directory is a
/// change entry like any other, not a path one descends into).
pub fn matchPath(path: []const u8) []const u8 {
    var p = path;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    while (p.len > 0 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    return p;
}

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

pub fn parse(alloc: std.mem.Allocator, text: []const u8) Error!Report {
    var report = Report{ .text = text };
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(alloc);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = trim(raw);
        if (line.len == 0 or line[0] == '#') continue;

        // Header: `@key value`. Unknown keys are ignored so an older poof can
        // still read a report written by a newer one.
        if (line[0] == '@') {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const key = line[1..space];
            const value = trim(line[space + 1 ..]);
            if (value.len == 0) continue;
            if (std.mem.eql(u8, key, "stash")) report.stash = value;
            if (std.mem.eql(u8, key, "target")) report.target = value;
            if (std.mem.eql(u8, key, "mode")) report.mode = value;
            continue;
        }

        var entry = Entry{};
        if (line[0] == '!') {
            entry.exclude = true;
            line = trim(line[1..]);
        }
        // The kind marker is poof's own change-list prefix, and it is only a
        // marker when it is followed by whitespace: `-foo.txt` is a file name.
        if (line.len >= 2) {
            if (kindOfChar(line[0])) |kind| {
                if (line[1] == ' ' or line[1] == '\t') {
                    entry.kind = kind;
                    line = trim(line[2..]);
                }
            }
        }
        if (line.len == 0) continue;
        entry.pattern = line;
        entries.append(alloc, entry) catch return error.OutOfMemory;
    }

    report.entries = entries.toOwnedSlice(alloc) catch return error.OutOfMemory;
    return report;
}

pub fn load(alloc: std.mem.Allocator, path: []const u8) Error!Report {
    const p = posix.toPosixPath(path) catch return error.CannotRead;
    const opened = linux.open(&p, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (sandbox.errnoFromSyscall(opened) != .SUCCESS) return error.CannotRead;
    const fd: posix.fd_t = @intCast(opened);
    defer _ = linux.close(fd);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &buf, buf.len);
        if (sandbox.errnoFromSyscall(n) != .SUCCESS) {
            // A directory reads as an error: not a report.
            if (text.items.len == 0) return error.CannotRead;
            break;
        }
        if (n == 0) break;
        if (text.items.len + n > max_report_bytes) return error.TooLarge;
        text.appendSlice(alloc, buf[0..n]) catch return error.OutOfMemory;
    }

    // On any failure below, load's errdefer frees the buffer the entries point
    // into, so a half-read report leaks nothing.
    var report = try parse(alloc, text.items);
    report.text = text.items;
    report.owns_text = true;
    return report;
}

pub fn save(path: []const u8, text: []const u8) Error!void {
    const p = posix.toPosixPath(path) catch return error.CannotWrite;
    const opened = linux.open(
        &p,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true },
        0o644,
    );
    if (sandbox.errnoFromSyscall(opened) != .SUCCESS) return error.CannotWrite;
    const fd: posix.fd_t = @intCast(opened);
    defer _ = linux.close(fd);

    var rest: []const u8 = text;
    while (rest.len > 0) {
        const written = linux.write(fd, rest.ptr, rest.len);
        if (sandbox.errnoFromSyscall(written) != .SUCCESS) return error.CannotWrite;
        if (written == 0) return error.CannotWrite;
        rest = rest[written..];
    }
}

pub const Summary = struct {
    stash: []const u8,
    target: []const u8,
    /// "applied" or "dry-run": whether these changes reached the target.
    mode: []const u8,
    at: ?i64 = null,
    changes: []const Change,
};

pub fn format(alloc: std.mem.Allocator, summary: Summary) Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);

    text.appendSlice(alloc,
        \\# poof report v1
        \\# The changes one poof apply put (or would put, with --dry-run) onto the
        \\# target. Each line below is a glob over the paths poof printed: edit it,
        \\# then replay what matches with:  poof apply --from=<this file>
        \\#   + added   ~ edited   - deleted   ! never these
        \\# Patterns are shell globs over paths relative to @target: * stays inside one
        \\# directory, **/ spans any number of them, {a,b} and [a-z] as in a shell.
        \\# A leading dot is not special, so src/* covers src/.hidden.
        \\
    ) catch return error.OutOfMemory;

    text.print(alloc, "@stash {s}\n", .{summary.stash}) catch return error.OutOfMemory;
    text.print(alloc, "@target {s}\n", .{summary.target}) catch return error.OutOfMemory;
    text.print(alloc, "@mode {s}\n", .{summary.mode}) catch return error.OutOfMemory;
    text.print(alloc, "@changed {d}\n", .{summary.changes.len}) catch return error.OutOfMemory;
    if (summary.at) |at| {
        text.print(alloc, "@time {d}\n", .{at}) catch return error.OutOfMemory;
    }
    text.append(alloc, '\n') catch return error.OutOfMemory;

    for (summary.changes) |change| {
        text.append(alloc, kindChar(change.change_type)) catch return error.OutOfMemory;
        text.append(alloc, ' ') catch return error.OutOfMemory;
        text.appendSlice(alloc, matchPath(change.path)) catch return error.OutOfMemory;
        text.append(alloc, '\n') catch return error.OutOfMemory;
    }

    return text.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

/// `path` without `base`, in the form patterns are matched in. A session prints
/// its changes relative to the directory it worked in and records that as
/// @target, while a stash mirrors absolute paths - so removing the target the
/// report was written against is what lets both select the same change.
fn relativeTo(base: []const u8, path: []const u8) []const u8 {
    const p = matchPath(path);
    const b = matchPath(base);
    if (b.len == 0) return p;
    if (p.len > b.len + 1 and std.mem.startsWith(u8, p, b) and p[b.len] == '/') return matchPath(p[b.len + 1 ..]);
    return p;
}

/// True when `report` selects this change. A report with only `!` lines starts
/// from everything and subtracts; one that names anything selects just that.
/// `base` is the target the report was written against (its @target, or `/`).
pub fn matches(report: Report, change: Change, base: []const u8) bool {
    const path = relativeTo(base, change.path);
    var named: usize = 0;
    for (report.entries) |entry| {
        if (!entry.exclude) named += 1;
    }
    var selected = named == 0;

    for (report.entries) |entry| {
        if (entry.kind != null and entry.kind.? != change.change_type) continue;
        if (!zglob.globMatch(matchPath(entry.pattern), path)) continue;
        if (entry.exclude) return false;
        selected = true;
    }
    return selected;
}

// ---------------------------------------------------------------------------
// Unit tests: pure text and matching, no filesystem and no sandbox.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse reads the header, the patterns and the comments" {
    const text =
        \\# a comment
        \\@stash /tmp/poof-4f2a9c1b7d3e8a55
        \\@target /
        \\@mode applied
        \\@changed 4
        \\
        \\+ home/me/new.txt
        \\~ home/me/mod.txt
        \\- home/me/del.txt
        \\! build/**
        \\
    ;
    const report = try parse(testing.allocator, text);
    defer testing.allocator.free(report.entries);

    try testing.expectEqualStrings("/tmp/poof-4f2a9c1b7d3e8a55", report.stash.?);
    try testing.expectEqualStrings("/", report.target.?);
    try testing.expectEqualStrings("applied", report.mode.?);
    try testing.expectEqual(@as(usize, 4), report.entries.len);
    try testing.expectEqual(@as(?ChangeType, .added), report.entries[0].kind);
    try testing.expectEqualStrings("home/me/new.txt", report.entries[0].pattern);
    try testing.expectEqual(@as(?ChangeType, .deleted), report.entries[2].kind);
    try testing.expectEqual(@as(?ChangeType, null), report.entries[3].kind);
    try testing.expect(report.entries[3].exclude);
}

test "a kind marker is only a marker when a space follows it" {
    const report = try parse(testing.allocator, "- foo.txt\n-plus.txt\n");
    defer testing.allocator.free(report.entries);

    try testing.expectEqual(@as(?ChangeType, .deleted), report.entries[0].kind);
    try testing.expectEqualStrings("foo.txt", report.entries[0].pattern);
    try testing.expectEqual(@as(?ChangeType, null), report.entries[1].kind);
    try testing.expectEqualStrings("-plus.txt", report.entries[1].pattern);
}

test "an exact path selects its change and only it" {
    const report = try parse(testing.allocator, "src/main.zig\n");
    defer testing.allocator.free(report.entries);

    try testing.expect(matches(report, .{ .path = "/src/main.zig", .change_type = .edited }, "/"));
    try testing.expect(!matches(report, .{ .path = "/src/main.h", .change_type = .edited }, "/"));
    try testing.expect(!matches(report, .{ .path = "/src/deep/main.zig", .change_type = .edited }, "/"));
}

test "globs widen a report: * stays inside one directory, **/ crosses them" {
    const report = try parse(testing.allocator, "src/*.c\nsrc/**/*.h\n");
    defer testing.allocator.free(report.entries);

    try testing.expect(matches(report, .{ .path = "src/a.c", .change_type = .added }, "/"));
    try testing.expect(!matches(report, .{ .path = "src/deep/b.c", .change_type = .added }, "/"));
    try testing.expect(matches(report, .{ .path = "src/deep/b.h", .change_type = .edited }, "/"));
    // A globstar spans zero directories too, which is what makes `**/x.log` work.
    try testing.expect(matches(report, .{ .path = "src/b.h", .change_type = .edited }, "/"));
}

test "braces and classes work as they do in a shell" {
    const braces = try parse(testing.allocator, "src/*.{c,h}\n");
    defer testing.allocator.free(braces.entries);

    try testing.expect(matches(braces, .{ .path = "src/a.c", .change_type = .added }, "/"));
    try testing.expect(matches(braces, .{ .path = "src/a.h", .change_type = .added }, "/"));
    try testing.expect(!matches(braces, .{ .path = "src/a.hpp", .change_type = .added }, "/"));

    const classes = try parse(testing.allocator, "src/x[0-9].c\n");
    defer testing.allocator.free(classes.entries);

    try testing.expect(matches(classes, .{ .path = "src/x7.c", .change_type = .added }, "/"));
    try testing.expect(!matches(classes, .{ .path = "src/x77.c", .change_type = .added }, "/"));
}

test "an exclusion beats a broader pattern that also matched" {
    const report = try parse(testing.allocator, "src/**\n! src/vendor/**\n");
    defer testing.allocator.free(report.entries);

    try testing.expect(matches(report, .{ .path = "src/main.zig", .change_type = .edited }, "/"));
    try testing.expect(!matches(report, .{ .path = "src/vendor/lib.zig", .change_type = .edited }, "/"));
}

test "a report with only exclusions keeps everything else" {
    const report = try parse(testing.allocator, "! **/*.log\n");
    defer testing.allocator.free(report.entries);

    try testing.expect(matches(report, .{ .path = "home/me/proj/x.c", .change_type = .added }, "/"));
    try testing.expect(!matches(report, .{ .path = "home/me/proj/x.log", .change_type = .added }, "/"));
}

test "patterns are matched relative to the target the report was written against" {
    // A session prints its changes relative to the directory it worked in, and a
    // stash mirrors absolute paths: the same line has to select both.
    const session = try parse(testing.allocator, "@target /home/me/proj\nsrc/main.zig\n");
    defer testing.allocator.free(session.entries);

    try testing.expect(matches(session, .{ .path = "/home/me/proj/src/main.zig", .change_type = .edited }, "/home/me/proj"));
    try testing.expect(matches(session, .{ .path = "src/main.zig", .change_type = .edited }, "/home/me/proj"));
    try testing.expect(!matches(session, .{ .path = "/home/me/other/src/main.zig", .change_type = .edited }, "/home/me/proj"));
    // Read against the root - what a stash of the same changes gives - the same
    // line only names the change once the mirror's own prefix is in it.
    try testing.expect(!matches(session, .{ .path = "home/me/proj/src/main.zig", .change_type = .edited }, "/"));
    try testing.expect(matches(session, .{ .path = "home/me/proj/src/main.zig", .change_type = .edited }, "/home/me/proj"));
}

test "a kind marker restricts the match to that kind of change" {
    const report = try parse(testing.allocator, "~ secrets.env\n");
    defer testing.allocator.free(report.entries);

    try testing.expect(matches(report, .{ .path = "secrets.env", .change_type = .edited }, "/"));
    try testing.expect(!matches(report, .{ .path = "secrets.env", .change_type = .added }, "/"));
}

test "an empty directory entry matches its pattern without the trailing slash" {
    const report = try parse(testing.allocator, "home/me/empty\n");
    defer testing.allocator.free(report.entries);

    try testing.expect(matches(report, .{ .path = "home/me/empty/", .change_type = .added }, "/"));
}

test "a written report reads back and selects the same changes" {
    const changes = [_]Change{
        .{ .path = "/home/me/new.txt", .change_type = .added },
        .{ .path = "/home/me/empty/", .change_type = .added },
        .{ .path = "/home/me/del.txt", .change_type = .deleted },
    };
    const text = try format(testing.allocator, .{
        .stash = "/tmp/poof-1",
        .target = "/",
        .mode = "applied",
        .changes = &changes,
    });
    defer testing.allocator.free(text);

    const written = try parse(testing.allocator, text);
    defer testing.allocator.free(written.entries);
    try testing.expectEqualStrings("/tmp/poof-1", written.stash.?);
    try testing.expectEqualStrings("applied", written.mode.?);

    const report = try parse(testing.allocator, text);
    defer testing.allocator.free(report.entries);

    for (changes) |change| try testing.expect(matches(report, change, "/"));
    try testing.expect(!matches(report, .{ .path = "/home/me/other.txt", .change_type = .edited }, "/"));
}

test "what ** does, and does not, reach" {
    const report_ = try parse(testing.allocator, "src/**\n");
    defer testing.allocator.free(report_.entries);

    // Any depth below the directory, however deep, and however many segments.
    try testing.expect(matches(report_, .{ .path = "src/a.c", .change_type = .added }, "/"));
    try testing.expect(matches(report_, .{ .path = "src/deep/deeper/f.h", .change_type = .added }, "/"));
    // The directory itself is a separate change (an added or replaced directory
    // is its own entry), so naming its contents does not name it.
    try testing.expect(!matches(report_, .{ .path = "src", .change_type = .added }, "/"));
    try testing.expect(!matches(report_, .{ .path = "other/a.c", .change_type = .added }, "/"));
}

test "a glob star in the middle spans zero directories, and ** alone spans any path" {
    const zero = try parse(testing.allocator, "src/**/*.c\n");
    defer testing.allocator.free(zero.entries);
    try testing.expect(matches(zero, .{ .path = "src/a.c", .change_type = .added }, "/"));
    try testing.expect(matches(zero, .{ .path = "src/a/b/c.c", .change_type = .added }, "/"));

    const every = try parse(testing.allocator, "**\n");
    defer testing.allocator.free(every.entries);
    try testing.expect(matches(every, .{ .path = "a/b/c", .change_type = .edited }, "/"));
    try testing.expect(matches(every, .{ .path = "a", .change_type = .edited }, "/"));
}

test "patterns are not shell about leading dots: * covers a hidden name" {
    // Worth pinning, because it is what makes `! **/*.log` also exclude a
    // `.build.log`, and `src/*` also take `src/.hidden`.
    const hidden = try parse(testing.allocator, "src/*\n");
    defer testing.allocator.free(hidden.entries);
    try testing.expect(matches(hidden, .{ .path = "src/.hidden", .change_type = .added }, "/"));
}
