// hello!
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = std.c;
const options = @import("build_options");

const output = @import("output.zig");
const sandbox = @import("sandbox.zig");

// Version info (set at build time)
const version = options.version;
const git_commit = options.git_commit;
const git_commit_explicit = options.git_commit_explicit;

// Re-exports from modules
const allocator = sandbox.allocator;
const Config = sandbox.Config;
const Keep = sandbox.Keep;
const ApplyAtExit = sandbox.ApplyAtExit;

// The old mode words, still accepted. They named a disposition of the changes, not a
// kind of sandbox - the sandbox is the same in every case - so they are now flags.
const Alias = enum { exec, run, enter };

const step = output.step;
const vstep = output.vstep;
const success = output.success;
const log = output.log;
const err = output.err;
const warn = output.warn;
const info = output.info;
const col = output.col;
const print = output.print;
const Color = output.Color;

fn parseSize(s: []const u8) !u64 {
    if (s.len == 0) return error.InvalidSize;

    var num_end: usize = 0;
    for (s) |ch| {
        if (ch >= '0' and ch <= '9') {
            num_end += 1;
        } else {
            break;
        }
    }

    if (num_end == 0) return error.InvalidSize;

    const num = try std.fmt.parseInt(u64, s[0..num_end], 10);
    const suffix = s[num_end..];

    if (suffix.len == 0) return num;

    const multiplier: u64 = switch (suffix[0]) {
        'k', 'K' => 1024,
        'm', 'M' => 1024 * 1024,
        'g', 'G' => 1024 * 1024 * 1024,
        else => return error.InvalidSize,
    };

    return num * multiplier;
}

fn clockSecs(clk: posix.clockid_t) ?i64 {
    var ts = posix.timespec{ .sec = 0, .nsec = 0 };
    const r = linux.clock_gettime(clk, &ts);
    if (sandbox.errnoFromSyscall(r) != .SUCCESS) return null;
    return ts.sec;
}

// C library functions for terminal control
extern "c" fn tcsetpgrp(fd: c_int, pgrp: c_int) c_int;
extern "c" fn getpgrp() c_int;

// Signal handler state
var child_pid: i32 = 0;

// Set before fork when an interactive run/enter session is active. An abnormal
// exit (timeout or signal) must stash the changes instead of deleting them.
var interactive_upper: ?[]const u8 = null;
var interactive_changes_path: ?[]const u8 = null;

fn signalHandler(sig: linux.SIG) callconv(.c) void {
    // Forward signal to child and wait for it to exit, so the mounts are torn down
    // before poof leaves. The wait is bounded: a sandbox that never acts on the
    // signal must not leave poof blocked here holding the terminal open.
    if (child_pid > 0) {
        _ = linux.kill(child_pid, sig);
        var status: i32 = 0;
        var waited_ms: u32 = 0;
        var reaped = false;
        while (waited_ms < 2000) {
            const r = linux.waitpid(child_pid, &status, linux.W.NOHANG);
            const e = sandbox.errnoFromSyscall(r);
            if (e == .SUCCESS) {
                reaped = true;
                break;
            }
            if (e == .CHILD) break; // already gone
            sandbox.sleepNs(0, 10_000_000);
            waited_ms += 10;
        }
        if (!reaped) {
            _ = linux.kill(child_pid, linux.SIG.KILL);
            _ = linux.waitpid(child_pid, &status, 0);
        }
    }
    // Don't destroy an interrupted session's work: stash it and say where.
    stashInteractiveChanges();
    // Cleanup cgroups and temp dirs
    sandbox.cleanupCgroup();
    sandbox.cleanupOverlayDirs();
    // Re-raise signal to get default behavior (exit with signal)
    var default_action: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.DFL },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(sig, &default_action, null);
    _ = linux.kill(linux.getpid(), sig);
}

fn setupSignalHandlers() void {
    var action: linux.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = linux.sigemptyset(),
        .flags = linux.SA.RESTART,
    };
    _ = linux.sigaction(linux.SIG.INT, &action, null);
    _ = linux.sigaction(linux.SIG.TERM, &action, null);
    _ = linux.sigaction(linux.SIG.HUP, &action, null);
}

fn reclaimTerminal() void {
    if (c.isatty(posix.STDIN_FILENO) != 1) return;

    // Block SIGTTOU/SIGTTIN while we reclaim the terminal
    // (calling tcsetpgrp from background can trigger these)
    var mask = linux.sigemptyset();
    linux.sigaddset(&mask, linux.SIG.TTOU);
    linux.sigaddset(&mask, linux.SIG.TTIN);
    var old_mask: linux.sigset_t = undefined;
    _ = linux.sigprocmask(linux.SIG.BLOCK, &mask, &old_mask);

    _ = tcsetpgrp(posix.STDIN_FILENO, getpgrp());

    // Restore original signal mask
    _ = linux.sigprocmask(linux.SIG.SETMASK, &old_mask, null);
}

// Wait for a child; pid == 0 means "no state change" (W.NOHANG),
// pid < 0 means the wait itself failed.
const WaitResult = struct { pid: i32, status: u32 };

fn waitChild(pid: i32, flags: u32) WaitResult {
    var status: i32 = 0;
    const r = linux.waitpid(pid, &status, flags);
    if (sandbox.errnoFromSyscall(r) != .SUCCESS) return .{ .pid = -1, .status = 0 };
    return .{ .pid = @intCast(r), .status = @bitCast(status) };
}

fn exitCodeFromStatus(status: u32) u8 {
    if ((status & 0x7f) == 0) return @truncate((status >> 8) & 0xff);
    if (((status & 0x7f) + 1) >> 1 > 0) return 128 + @as(u8, @truncate(status & 0x7f));
    return 1;
}

fn readStdin(buf: []u8) ?usize {
    const n = linux.read(posix.STDIN_FILENO, buf.ptr, buf.len);
    if (sandbox.errnoFromSyscall(n) != .SUCCESS) return null;
    return n;
}

fn zPath(path: []const u8) ?[*:0]const u8 {
    return allocator.dupeSentinel(u8, path, 0) catch return null;
}

// lstat without std.posix: its stat helpers sit behind std.Io in this Zig
// release, so use statx with AT.SYMLINK_NOFOLLOW directly.
const FileInfo = struct {
    mode: u32,
    is_link: bool,
    is_reg: bool,
    is_char: bool,
    is_whiteout_dev: bool, // character device 0:0, i.e. an overlay whiteout
};

fn fileInfo(path_z: [*:0]const u8) ?FileInfo {
    var sx: linux.Statx = undefined;
    const r = linux.statx(linux.AT.FDCWD, path_z, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &sx);
    if (sandbox.errnoFromSyscall(r) != .SUCCESS) return null;
    const mode: u32 = sx.mode;
    return .{
        .mode = mode,
        .is_link = linux.S.ISLNK(mode),
        .is_reg = linux.S.ISREG(mode),
        .is_char = linux.S.ISCHR(mode),
        .is_whiteout_dev = sx.rdev_major == 0 and sx.rdev_minor == 0,
    };
}

// Overlay whiteouts: a file deleted inside the sandbox is recorded in the upper
// dir as a character device with rdev 0 (both the kernel driver and
// fuse-overlayfs do this), or as a regular file named ".wh.<name>". A real
// character device created by the sandboxed program has a non-zero rdev, so the
// two are told apart by rdev.
fn whiteoutName(name: []const u8) ?[]const u8 {
    if (name.len <= 4) return null;
    if (!std.mem.startsWith(u8, name, ".wh.")) return null;
    return name[4..];
}

// fuse-overlayfs bookkeeping that must never be replayed onto the target:
// ".wh..wh..opq" (opaque-dir marker, regular file), ".wh..opq" (the same marker
// as a 0:0 char device) and friends.
fn isOverlayMarker(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, ".wh..wh.")) return true;
    return std.mem.eql(u8, name, ".wh..opq");
}

// Kernel overlayfs records an opaque directory as the "trusted.overlay.opaque"
// xattr ("user." prefixed on an unprivileged mount); only fuse-overlayfs and
// older kernels also leave a ".wh..wh..opq" file behind. getxattr has no wrapper
// in this Zig release, so the syscall is issued directly.
fn isOpaqueByXattr(path_z: [*:0]const u8) bool {
    var buf: [4]u8 = undefined;
    // getxattr takes a NUL-terminated name, hence [*:0] rather than []const u8.
    const names = [_][*:0]const u8{ "trusted.overlay.opaque", "user.overlay.opaque" };
    for (names) |name| {
        const r = linux.syscall3(linux.SYS.getxattr, @intFromPtr(path_z), @intFromPtr(name), @intFromPtr(&buf));
        if (sandbox.errnoFromSyscall(@intCast(r)) != .SUCCESS) continue;
        if (r >= 1 and buf[0] == 'y') return true;
    }
    return false;
}

// A directory the sandbox created is marked opaque: its contents replace the
// target directory's contents entirely. readdir hands the marker back in
// arbitrary order, so it has to be looked for before the contents are replayed.
fn hasOpaqueMarker(src_dir: []const u8) bool {
    // The xattr form first: it is what the kernel driver leaves, and it is there
    // even when the directory ended up empty.
    if (zPath(src_dir)) |z| {
        if (isOpaqueByXattr(z)) return true;
    }
    var dir = sandbox.DirStream.open(src_dir) orelse return false;
    defer dir.close();
    while (dir.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".wh..wh..opq") or std.mem.eql(u8, entry.name, ".wh..opq")) return true;
    }
    return false;
}

// Both representations of a deletion: the 0:0 character device (kernel driver
// and fuse-overlayfs) and the ".wh.<name>" regular file (userspace whiteout).
fn isWhiteout(name: []const u8, entry_kind: sandbox.DirEntryKind, stat: ?FileInfo) bool {
    if (entry_kind != .directory and whiteoutName(name) != null) return true;
    if (stat) |fi| {
        if (fi.is_char) return fi.is_whiteout_dev;
        return false;
    }
    // statx unavailable (pre-4.11 kernel): fall back to the dirent type.
    return entry_kind == .character_device;
}

// Commands that do not start a sandbox: they work on what a sandbox left behind.
const Subcommand = enum { apply, stash };

const ChangeType = enum { added, edited, deleted };

const Change = struct {
    path: []const u8,
    change_type: ChangeType,
};

const ChangeList = struct {
    items: []Change,
    len: usize,

    fn append(self: *ChangeList, change: Change) void {
        if (self.len < self.items.len) {
            self.items[self.len] = change;
            self.len += 1;
        }
    }
};

// True when the directory holds at least one entry that is not overlay
// bookkeeping.
fn dirHasRealEntries(path: []const u8) bool {
    var dir = sandbox.DirStream.open(path) orelse return false;
    defer dir.close();
    while (dir.next()) |entry| {
        if (isOverlayMarker(entry.name)) continue;
        return true;
    }
    return false;
}

// Recursively collect changed files in upper dir
fn collectChanges(upper_path: []const u8, target_dir: []const u8, strip_prefix: []const u8, changes: *ChangeList) void {
    var dir = sandbox.DirStream.open(upper_path) orelse return;
    defer dir.close();

    while (dir.next()) |entry| {
        if (isOverlayMarker(entry.name)) continue;

        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ upper_path, entry.name }) catch continue;

        // Build display path (relative to target)
        const display_path = if (std.mem.startsWith(u8, full_path, strip_prefix))
            full_path[strip_prefix.len..]
        else
            full_path;

        if (entry.kind == .directory) {
            // A directory the sandbox created holds only overlay markers until
            // something is put inside it, so "empty" has to ignore those.
            const has_children = dirHasRealEntries(full_path);

            if (has_children) {
                // Recurse into subdirectories with contents
                collectChanges(full_path, target_dir, strip_prefix, changes);
            } else {
                // Empty directory - new dir
                const path_with_slash = std.fmt.allocPrint(allocator, "{s}/", .{display_path}) catch continue;
                changes.append(.{ .path = path_with_slash, .change_type = .added });
            }
        } else if (entry.kind == .character_device or whiteoutName(entry.name) != null) {
            const src_z = zPath(full_path) orelse continue;
            if (isWhiteout(entry.name, entry.kind, fileInfo(src_z))) {
                // Deleted: show the name the entry had in the target, not the
                // ".wh." marker that stands in for it.
                var shown = display_path;
                if (whiteoutName(entry.name)) |base| {
                    if (std.mem.endsWith(u8, display_path, entry.name)) {
                        shown = std.fmt.allocPrint(allocator, "{s}{s}", .{
                            display_path[0 .. display_path.len - entry.name.len],
                            base,
                        }) catch continue;
                    }
                }
                changes.append(.{ .path = shown, .change_type = .deleted });
            } else {
                // A real character device the sandbox created.
                changes.append(.{ .path = display_path, .change_type = .added });
            }
        } else {
            // Check if file exists in target (edited) or not (added)
            const target_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ target_dir, display_path }) catch continue;
            const change_type: ChangeType = if (sandbox.pathExists(target_path))
                .edited
            else
                .added;
            changes.append(.{ .path = display_path, .change_type = change_type });
        }
    }
}

fn printChanges(changes: []const Change, upper_dir: []const u8) void {
    const red = col(Color.red);
    const green = col(Color.green);
    const yellow = col(Color.yellow);
    const reset = col(Color.reset);
    const bold_blue = col(Color.bold_blue);
    const bold = col(Color.bold);
    const dim = col(Color.dim);

    // Print summary line with temp folder path
    print("{s}────{s}\n", .{ dim, reset });
    print("{s}poof{s}: {s}{d} changed file{s}{s} {s}\n", .{
        bold_blue,
        reset,
        bold,
        changes.len,
        if (changes.len == 1) "" else "s",
        reset,
        upper_dir,
    });

    // Print each change with colored prefix only
    for (changes) |change| {
        // Strip leading / from path
        const path = if (change.path.len > 0 and change.path[0] == '/')
            change.path[1..]
        else
            change.path;

        switch (change.change_type) {
            .deleted => print("  {s}-{s} {s}\n", .{ red, reset, path }),
            .added => print("  {s}+{s} {s}\n", .{ green, reset, path }),
            .edited => print("  {s}~{s} {s}\n", .{ yellow, reset, path }),
        }
    }
}

// Deal with a session's changes at exit: apply them straight away when the session
// said to (--yes), otherwise show the list and ask. A session that only stashed its
// changes never gets here; `poof apply <stash>` is how those come back.
fn handleExitApply(config: Config) void {
    const upper_dir = config.upper_dir orelse return;
    const target_dir = config.apply_target orelse return;

    // Reclaim the terminal - the child shell was the foreground process group
    reclaimTerminal();

    // The changes to target_dir are in upper_dir + target_dir path
    const changes_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ upper_dir, target_dir }) catch return;

    // Check if any changes exist
    var dir = sandbox.DirStream.open(changes_path) orelse {
        success("No changes made to {s}", .{target_dir});
        return;
    };
    defer dir.close();

    // Count changes
    var change_count: usize = 0;
    while (dir.next() != null) {
        change_count += 1;
    }

    if (change_count == 0) {
        success("No changes made to {s}", .{target_dir});
        return;
    }

    // Collect all changes (max 1000)
    var change_buf: [1000]Change = undefined;
    var changes = ChangeList{ .items = &change_buf, .len = 0 };
    collectChanges(changes_path, target_dir, changes_path, &changes);

    if (changes.len == 0) {
        success("No changes made to {s}", .{target_dir});
        return;
    }

    print("\n", .{});
    printChanges(changes.items[0..changes.len], upper_dir);
    print("\n", .{});

    if (config.apply_at_exit == .always) {
        // --yes: the list above is the notice, there is no question to ask.
        applyChanges(changes_path, target_dir);
        return;
    }

    // Prompt user
    const c1 = col(Color.bold_yellow);
    const c2 = col(Color.reset);
    print("{s}Apply these changes to {s}?{s} [y/N/d(iff)]: ", .{ c1, target_dir, c2 });

    // Read user input
    var input_buf: [16]u8 = undefined;
    const n = readStdin(&input_buf) orelse {
        print("\n", .{});
        keepChanges(upper_dir);
        return;
    };
    const input = input_buf[0..n];

    const trimmed = std.mem.trim(u8, input, " \t\r\n");

    if (std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "Y") or std.mem.eql(u8, trimmed, "yes")) {
        // Apply changes using rsync or cp
        applyChanges(changes_path, target_dir);
    } else if (std.mem.eql(u8, trimmed, "d") or std.mem.eql(u8, trimmed, "D") or std.mem.eql(u8, trimmed, "diff")) {
        // Show full diff (--no-pager to avoid "terminal not fully functional" issues)
        const full_diff_argv = [_][]const u8{ "git", "--no-pager", "diff", "--no-index", target_dir, changes_path };
        const diff_rc = sandbox.runProcess(&full_diff_argv);
        if (diff_rc == null or diff_rc.? == 127) {
            // execvp failed in the child, which exits 127 silently: say why the
            // diff is missing instead of leaving the prompt with no output.
            warn("cannot show diff: git is not installed", .{});
        }

        // Prompt again
        print("\n{s}Apply these changes?{s} [y/N]: ", .{ c1, c2 });
        var input_buf2: [16]u8 = undefined;
        const n2 = readStdin(&input_buf2) orelse {
            print("\n", .{});
            keepChanges(upper_dir);
            return;
        };
        const trimmed2 = std.mem.trim(u8, input_buf2[0..n2], " \t\r\n");
        if (std.mem.eql(u8, trimmed2, "y") or std.mem.eql(u8, trimmed2, "Y")) {
            applyChanges(changes_path, target_dir);
        } else {
            keepChanges(upper_dir);
        }
    } else {
        keepChanges(upper_dir);
    }
}

// True when a directory exists and holds at least one entry.
fn hasDirEntries(path: []const u8) bool {
    var dir = sandbox.DirStream.open(path) orelse return false;
    defer dir.close();
    return dir.next() != null;
}

// A session that was killed (timeout/signal) never got to apply or prompt, so keep
// its upper dir and tell the user where to find it.
fn stashInteractiveChanges() void {
    const upper_dir = interactive_upper orelse return;
    const changes_path = interactive_changes_path orelse return;
    if (hasDirEntries(changes_path)) keepChanges(upper_dir);
}

fn keepChanges(upper_dir: []const u8) void {
    // Don't delete the temp dir - user wants to keep it
    sandbox.cleanup_temp_base = null;
    // The overlay work dir (<upper>.work) is only meaningful while the overlay is
    // mounted: whiteouts live in the upper dir, so once we are done with the mount
    // it is dead weight. Keep it out of the stash; a fresh workdir can be created
    // if the stash ever gets mounted again to browse.
    // cleanup_merged_base stays: it only ever holds the overlay mount point, never user data
    const dim = col(Color.dim);
    const r = col(Color.reset);
    print("{s}Stashed changes in{s} {s}\n", .{ dim, r, upper_dir });
}

const ApplyStats = struct {
    applied: usize = 0,
    failed: usize = 0,
};

// Remove a destination entry without following symlinks out of the target tree.
fn removeTarget(path: []const u8) void {
    const z = zPath(path) orelse return;
    if (fileInfo(z)) |fi| {
        if (fi.is_link) {
            _ = linux.unlink(z);
            return;
        }
    }
    sandbox.deleteTree(path);
}

// An opaque overlay directory (".wh..wh..opq") replaces the target directory's
// contents entirely.
fn clearDir(dir_path: []const u8, stats: *ApplyStats) void {
    var dir = sandbox.DirStream.open(dir_path) orelse return;
    defer dir.close();
    while (dir.next()) |entry| {
        const child = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        removeTarget(child);
        stats.applied += 1;
    }
}

fn copyFile(src_z: [*:0]const u8, dst_z: [*:0]const u8, mode: u32, stats: *ApplyStats) void {
    const opened = linux.open(src_z, .{ .ACCMODE = .RDONLY }, 0);
    if (sandbox.errnoFromSyscall(opened) != .SUCCESS) {
        err("cannot read {s}", .{src_z});
        stats.failed += 1;
        return;
    }
    const src_fd: posix.fd_t = @intCast(opened);
    defer _ = linux.close(src_fd);

    // Replace whatever is at the destination so a stale entry of another type
    // cannot survive the apply.
    _ = linux.unlink(dst_z);
    const created = linux.open(
        dst_z,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true },
        @truncate(mode & 0o7777),
    );
    if (sandbox.errnoFromSyscall(created) != .SUCCESS) {
        err("cannot write {s}", .{dst_z});
        stats.failed += 1;
        return;
    }
    const dst_fd: posix.fd_t = @intCast(created);
    defer _ = linux.close(dst_fd);

    var buf: [65536]u8 = undefined;
    while (true) {
        const n = linux.read(src_fd, &buf, buf.len);
        if (sandbox.errnoFromSyscall(n) != .SUCCESS) {
            err("read failed: {s}", .{src_z});
            stats.failed += 1;
            return;
        }
        if (n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const w = linux.write(dst_fd, buf[off..n].ptr, n - off);
            if (sandbox.errnoFromSyscall(w) != .SUCCESS) {
                err("write failed: {s}", .{dst_z});
                stats.failed += 1;
                return;
            }
            off += w;
        }
    }

    // open() applies the umask; restore the mode the sandboxed process saw.
    _ = linux.fchmod(dst_fd, @truncate(mode & 0o7777));
    stats.applied += 1;
}

// Walk the upper dir and replay it onto the target: whiteouts become deletions,
// directories are created and recursed, symlinks are recreated as symlinks and
// regular files are copied with their mode. `cp -r` cannot do any of the first
// two, which is why this is hand rolled.
fn applyTree(src_dir: []const u8, dst_dir: []const u8, stats: *ApplyStats) void {
    var dir = sandbox.DirStream.open(src_dir) orelse {
        err("cannot read changes in {s}", .{src_dir});
        stats.failed += 1;
        return;
    };
    defer dir.close();

    if (!sandbox.pathExists(dst_dir)) {
        sandbox.makeDirs(dst_dir) catch |e| {
            err("cannot create {s}: {}", .{ dst_dir, e });
            stats.failed += 1;
            return;
        };
    }

    // Never let an opaque marker wipe the filesystem root: that would be the
    // upper dir's own marker, not a user replacing a directory.
    if (hasOpaqueMarker(src_dir) and !std.mem.eql(u8, dst_dir, "/")) clearDir(dst_dir, stats);

    while (dir.next()) |entry| {
        // Overlay bookkeeping, never user data.
        if (isOverlayMarker(entry.name)) continue;

        const src_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_dir, entry.name }) catch continue;
        const src_z = zPath(src_path) orelse continue;

        const fi = fileInfo(src_z);

        var dst_name: []const u8 = entry.name;
        if (whiteoutName(entry.name)) |base| dst_name = base;
        if (dst_name.len == 0) continue;
        const dst_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dst_dir, dst_name }) catch continue;
        const dst_z = zPath(dst_path) orelse continue;

        if (isWhiteout(entry.name, entry.kind, fi)) {
            removeTarget(dst_path);
            stats.applied += 1;
            continue;
        }

        if (entry.kind == .directory) {
            applyTree(src_path, dst_path, stats);
            continue;
        }

        if (fi != null and fi.?.is_link) {
            var link_buf: [4096]u8 = undefined;
            const n = linux.readlinkat(linux.AT.FDCWD, src_z, &link_buf, link_buf.len);
            if (sandbox.errnoFromSyscall(n) != .SUCCESS or n == 0 or n > link_buf.len) {
                err("cannot read symlink {s}", .{src_z});
                stats.failed += 1;
                continue;
            }
            const link = allocator.dupeSentinel(u8, link_buf[0..n], 0) catch continue;
            removeTarget(dst_path);
            if (sandbox.errnoFromSyscall(linux.symlinkat(link, linux.AT.FDCWD, dst_z)) != .SUCCESS) {
                err("cannot create symlink {s}", .{dst_z});
                stats.failed += 1;
                continue;
            }
            stats.applied += 1;
            continue;
        }

        if (fi != null and fi.?.is_reg) {
            copyFile(src_z, dst_z, fi.?.mode, stats);
            continue;
        }

        warn("skipping unsupported file type: {s}", .{src_path});
        stats.failed += 1;
    }
}

fn applyChanges(source: []const u8, target: []const u8) void {
    step("Applying changes to {s}", .{target});

    var stats = ApplyStats{};
    applyTree(source, target, &stats);

    if (stats.failed == 0) {
        success("Changes applied successfully ({d})", .{stats.applied});
    } else {
        err("applied {d} change(s), {d} failed", .{ stats.applied, stats.failed });
    }
}

// ============================================================================
// Stash lifecycle: list saved upper dirs and replay them onto the host
// ============================================================================

// A stash is an upper dir: its contents mirror absolute paths, so the target of
// every entry is encoded in the path itself and no sidecar metadata is needed.
// Lexical path cleanup: std.fs.path.normalize is gone in this Zig release. Only
// the simple form is needed here, so that `poof apply .` inside a stash names
// the same directory as the same stash given by an absolute path.
fn normalizePath(alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    var segments: [256][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (n == 0) return null; // would escape the root
            n -= 1;
            continue;
        }
        if (n >= segments.len) return null;
        segments[n] = seg;
        n += 1;
    }
    if (n == 0) return alloc.dupe(u8, "/") catch null;
    const joined = std.mem.join(alloc, "/", segments[0..n]) catch return null;
    if (path.len > 0 and path[0] == '/') return std.fmt.allocPrint(alloc, "/{s}", .{joined}) catch null;
    return joined;
}

fn resolveStash(input: []const u8, cwd: []const u8) ?[]const u8 {
    if (input.len == 0) return null;

    const joined = if (input[0] == '/')
        input
    else
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, input }) catch return null;

    // Normalized, so `poof apply .` inside a stash names the same directory as
    // an absolute path would (removeStash compares against the cwd).
    const abs = normalizePath(allocator, joined) orelse return null;

    if (std.mem.eql(u8, abs, "/")) {
        err("refusing to treat / as a stash", .{});
        return null;
    }
    if (!sandbox.isDirectory(abs)) {
        err("not a stash directory: {s}", .{abs});
        return null;
    }
    return abs;
}

fn collectStashChanges(stash: []const u8, changes: *ChangeList) void {
    // The upper dir mirrors absolute paths, so the target is the filesystem root.
    collectChanges(stash, "/", stash, changes);
}

fn applyStash(input: []const u8, cwd: []const u8, assume_yes: bool) u8 {
    const stash = resolveStash(input, cwd) orelse return 1;

    var change_buf: [1000]Change = undefined;
    var changes = ChangeList{ .items = &change_buf, .len = 0 };
    collectStashChanges(stash, &changes);

    if (changes.len == 0) {
        info("no changes in {s}", .{stash});
        return 0;
    }

    // The preview is the safety mechanism: applying writes straight to /.
    printChanges(changes.items[0..changes.len], stash);
    print("\n", .{});

    if (!assume_yes) {
        if (std.c.isatty(std.posix.STDIN_FILENO) != 1) {
            err("refusing to apply {d} change(s) to / without a terminal; pass --yes to confirm", .{changes.len});
            return 1;
        }
        const c1 = col(Color.bold_yellow);
        const c2 = col(Color.reset);
        print("{s}Apply these {d} change(s) to /?{s} [y/N]: ", .{ c1, changes.len, c2 });
        var input_buf: [16]u8 = undefined;
        const n = readStdin(&input_buf) orelse {
            print("\n", .{});
            return 130;
        };
        const trimmed = std.mem.trim(u8, input_buf[0..n], " \t\r\n");
        if (!(std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "Y") or std.mem.eql(u8, trimmed, "yes"))) {
            info("not applied; stash kept in {s}", .{stash});
            return 0;
        }
    }

    var stats = ApplyStats{};
    applyTree(stash, "/", &stats);

    if (stats.failed != 0) {
        err("applied {d} change(s), {d} failed", .{ stats.applied, stats.failed });
        info("stash kept in {s}; fix what failed and apply it again", .{stash});
        return 1;
    }

    // Fully applied: the upper dir has served its purpose and would otherwise
    // pile up in /tmp. Anything that failed above keeps the stash for a retry.
    if (removeStash(stash, cwd)) {
        success("Applied {d} change(s) and removed {s}", .{ stats.applied, stash });
    } else {
        success("Applied {d} change(s) from {s}", .{ stats.applied, stash });
    }
    return 0;
}

// Delete a stash that has been applied. Returns false when it was left in place
// on purpose. The stash is the upper dir; stashes saved by older poof versions
// also left the overlay work dir beside it, which is dead weight once unmounted.
fn removeStash(stash: []const u8, cwd: []const u8) bool {
    if (std.mem.eql(u8, stash, "/")) return false;
    if (std.mem.eql(u8, stash, cwd)) {
        warn("stash is the current directory; leaving it in place: {s}", .{stash});
        return false;
    }

    sandbox.deleteTree(stash);

    const work = std.fmt.allocPrint(allocator, "{s}.work", .{stash}) catch return false;
    if (sandbox.isDirectory(work)) sandbox.deleteTree(work);

    if (sandbox.pathExists(stash)) {
        warn("applied, but could not remove the stash: {s}", .{stash});
        return false;
    }
    return true;
}

fn formatAge(seconds: i64, buf: []u8) []const u8 {
    const abs = if (seconds < 0) -seconds else seconds;
    if (abs < 60) return std.fmt.bufPrint(buf, "{d}s ago", .{seconds}) catch "unknown";
    if (abs < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divTrunc(seconds, 60)}) catch "unknown";
    if (abs < 86400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divTrunc(seconds, 3600)}) catch "unknown";
    return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(seconds, 86400)}) catch "unknown";
}

fn stashAge(path_z: [*:0]const u8) ?i64 {
    var sx: linux.Statx = undefined;
    const r = linux.statx(linux.AT.FDCWD, path_z, linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &sx);
    if (sandbox.errnoFromSyscall(r) != .SUCCESS) return null;
    const now = clockSecs(posix.CLOCK.REALTIME) orelse return null;
    return now - sx.mtime.sec;
}

// poof names its temp upper dirs /tmp/poof-<16 hex>. Matching that exactly keeps
// unrelated /tmp/poof-* directories out of the listing; a stash the user chose
// with --upper=<dir> is applied by path, it is never listed.
fn isStashName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "poof-")) return false;
    const suffix = name[5..];
    if (suffix.len != 16) return false;
    for (suffix) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

fn listStashes() u8 {
    var dir = sandbox.DirStream.open("/tmp") orelse {
        err("cannot read /tmp", .{});
        return 1;
    };
    defer dir.close();

    const B = col(Color.bold);
    const D = col(Color.dim);
    const R = col(Color.reset);

    var found: usize = 0;
    while (dir.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!isStashName(entry.name)) continue;

        const path = std.fmt.allocPrint(allocator, "/tmp/{s}", .{entry.name}) catch continue;
        const path_z = zPath(path) orelse continue;

        var change_buf: [1000]Change = undefined;
        var changes = ChangeList{ .items = &change_buf, .len = 0 };
        collectStashChanges(path, &changes);
        if (changes.len == 0) continue; // an empty upper dir is not worth listing

        var age_buf: [32]u8 = undefined;
        const age = stashAge(path_z) orelse 0;
        print("  {s}{d}{s} change(s)  {s}{s}{s}  {s}\n", .{
            B,
            changes.len,
            R,
            D,
            formatAge(age, &age_buf),
            R,
            path,
        });
        found += 1;
    }

    if (found == 0) {
        info("no stashes with changes in /tmp", .{});
        log("a --upper=<dir> stash is applied by path: poof apply <dir>", .{});
        return 0;
    }
    print("\n", .{});
    info("apply one with: poof apply <dir>", .{});
    return 0;
}

pub fn run(config: Config) u8 {
    const orig_uid = linux.getuid();
    const orig_gid = linux.getgid();

    // Show startup info (minimal unless verbose)
    if (config.keep == .none) {
        vstep("Starting ephemeral environment", .{});
    } else if (config.apply_target != null) {
        // The session will deal with its changes for this directory on exit
        vstep("Starting session, changes for {s} kept in {s}", .{ config.apply_target.?, config.upper_dir orelse "(temp)" });
    } else {
        vstep("Starting session, changes kept in {s}", .{config.upper_dir orelse "(temp)"});
    }
    log("uid={} gid={}", .{ orig_uid, orig_gid });

    // The overlay's lower layer is the root mount, so a working directory that sits
    // on a mount below it is outside the sandbox's view: with the kernel driver the
    // mounted tree is not even visible inside, and either way writes there go to the
    // upper dir instead of that filesystem. Say so before running anything.
    var point_buf: [4096]u8 = undefined;
    var fstype_buf: [64]u8 = undefined;
    if (sandbox.mountOf(config.cwd, &point_buf, &fstype_buf)) |m| {
        if (!std.mem.eql(u8, m.point, "/")) {
            warn("{s} sits on the {s} mount at {s}, not the root filesystem", .{ config.cwd, m.fstype, m.point });
            info("poof overlays the root mount only: as root the mounted tree is not visible inside the sandbox, and writes there land in the upper dir instead", .{});
        }
    }

    // Set up cgroups BEFORE fork so child inherits limits
    if (config.memory_limit != null or config.pids_limit != null) {
        sandbox.setupCgroup(config) catch |cgroup_err| {
            if (cgroup_err == error.CgroupsNotAvailable) {
                err("cannot apply --memory/--pids: no place in the cgroup hierarchy allows creating a limited child cgroup", .{});
                info("try running as root, or check the cgroup delegation of your session (systemd) / container", .{});
            } else {
                err("cgroup setup failed: {}", .{cgroup_err});
            }
            return 1;
        };
        vstep("Resource limits applied", .{});
    }

    // Set up cleanup paths BEFORE fork (child sets globals but parent does cleanup)
    if (config.keep == .none) {
        // --no-keep: create temp dir now so parent knows the path to clean up
        sandbox.cleanup_temp_base = sandbox.makeTempDir() catch |e| {
            err("makeTempDir: {}", .{e});
            return 1;
        };
    } else {
        // Keeping changes: .work sits next to the upper dir (kernel overlay wants
        // upper and work on one filesystem); the merged mount point goes into a private
        // temp base so it stays invisible from inside the sandbox.
        sandbox.cleanup_work_dir = std.fmt.allocPrint(allocator, "{s}.work", .{config.upper_dir.?}) catch null;
        sandbox.cleanup_merged_base = sandbox.makeTempDir() catch |e| {
            err("makeTempDir: {}", .{e});
            return 1;
        };
        // A session that applies at exit owns its stash: it goes once the changes are
        // on the host. Declining the prompt clears this (keepChanges) instead.
        if (config.apply_at_exit != .never) {
            sandbox.cleanup_temp_base = config.upper_dir;
        }
    }

    // Remember what an abnormal exit must stash (a session that would have applied)
    if (config.apply_at_exit != .never) {
        interactive_upper = config.upper_dir;
        interactive_changes_path = std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ config.upper_dir.?, config.apply_target.? },
        ) catch null;
    }

    // Set up signal handlers BEFORE fork for cleanup on SIGTERM/SIGINT
    setupSignalHandlers();

    // Fork to create isolated child
    const forked = sandbox.forkChild();

    if (forked.pid == 0) {
        // Child
        sandbox.childMain(config, orig_uid, orig_gid);
    } else if (forked.pid > 0) {
        // Parent - wait for child with optional timeout
        child_pid = forked.pid;
        log("child pid={}", .{child_pid});

        if (config.timeout) |timeout_secs| {
            // Get monotonic time for timeout tracking
            const start_sec = clockSecs(posix.CLOCK.MONOTONIC) orelse {
                // Fall back to no timeout if clock fails
                const result = waitChild(child_pid, 0);
                sandbox.cleanupCgroup();
                sandbox.cleanupOverlayDirs();
                return exitCodeFromStatus(result.status);
            };
            const deadline_sec: i64 = start_sec + timeout_secs;

            while (true) {
                // Non-blocking wait
                const result = waitChild(child_pid, linux.W.NOHANG);
                if (result.pid < 0) continue; // wait failed (e.g. EINTR), retry
                if (result.pid != 0) {
                    // Child exited
                    sandbox.cleanupCgroup();
                    sandbox.cleanupOverlayDirs();
                    return exitCodeFromStatus(result.status);
                }

                // Check timeout
                const now_sec = clockSecs(posix.CLOCK.MONOTONIC) orelse continue;
                if (now_sec >= deadline_sec) {
                    warn("timeout after {d}s, killing process", .{timeout_secs});
                    _ = linux.kill(child_pid, linux.SIG.KILL);
                    _ = waitChild(child_pid, 0);
                    stashInteractiveChanges();
                    sandbox.cleanupCgroup();
                    sandbox.cleanupOverlayDirs();
                    return 124; // Standard timeout exit code
                }

                // Sleep briefly before checking again (10ms)
                sandbox.sleepNs(0, 10_000_000);
            }
        } else {
            // No timeout - blocking wait
            const result = waitChild(child_pid, 0);
            sandbox.cleanupCgroup();

            // The session asked for its changes to be dealt with on exit
            if (config.apply_target != null) {
                handleExitApply(config);
            }

            sandbox.cleanupOverlayDirs();

            return exitCodeFromStatus(result.status);
        }
    } else {
        err("fork failed: {}", .{forked.errno});
        sandbox.cleanupCgroup();
        sandbox.cleanupOverlayDirs();
        return 1;
    }
}

fn getHostCwd(buf: []u8) []const u8 {
    _ = c.getcwd(buf.ptr, buf.len) orelse return "/";
    for (buf, 0..) |ch, i| {
        if (ch == 0) return buf[0..i];
    }
    return "/";
}

fn printVersion() void {
    if (git_commit.len == 0) {
        print("poof {s}\n", .{version});
        return;
    }
    // A commit looked up at configure time is cached with build.zig and can lag
    // behind HEAD, so it is labelled rather than presented as fact.
    const provenance = if (git_commit_explicit) "" else ", from last configure";
    print("poof {s} ({s}{s})\n", .{ version, git_commit, provenance });
}

fn printApplyHelp() void {
    const C = col(Color.cyan);
    const B = col(Color.bold);
    const D = col(Color.dim);
    const R = col(Color.reset);

    print("\n", .{});
    print("{s}poof apply{s} \u{2014} Replay a saved upper dir (stash) onto the host\n", .{ C, R });

    print("\n{s}USAGE{s}\n", .{ B, R });
    print("  {s}poof apply{s} [options] <stash>\n", .{ C, R });
    print("  {s}poof --apply=<stash>{s}        the same, script-friendly\n", .{ C, R });

    print("\n{s}EXAMPLES{s}\n", .{ B, R });
    print("  $ poof stash list                  {s}# find stashes{s}\n", .{ D, R });
    print("  $ poof apply /tmp/poof-3f9a2b      {s}# preview, then confirm{s}\n", .{ D, R });
    print("  $ poof apply /tmp/poof-3f9a2b --yes\n", .{});

    print("\n{s}NOTES{s}\n", .{ B, R });
    print("  A stash mirrors absolute paths, so <stash>/home/me/proj/x.c applies\n", .{});
    print("  to /home/me/proj/x.c. Deletions are replayed as deletions (overlay\n", .{});
    print("  whiteouts), file modes and symlinks are preserved.\n", .{});
    print("  Applying writes straight to the filesystem: the change list is shown\n", .{});
    print("  first and confirmation is required unless --yes is given. A stash that\n", .{});
    print("  applies in full is removed; a partial failure keeps it for a retry.\n", .{});

    print("\n{s}OPTIONS{s}\n", .{ B, R });
    print("  {s}--yes{s}                      Apply without prompting\n", .{ C, R });
    print("  {s}-h, --help{s}                 Show this help\n", .{ C, R });
}

fn printModeHelp(mode: Alias) void {
    const C = col(Color.cyan);
    const B = col(Color.bold);
    const BB = col(Color.bold_blue);
    const G = col(Color.green);
    const Y = col(Color.yellow);
    const RE = col(Color.red);
    const D = col(Color.dim);
    const R = col(Color.reset);

    // The mode words stay so muscle memory and existing scripts keep working; what
    // the changes do is spelled with flags now, so say so before the old help.
    const replacement = switch (mode) {
        .exec => "poof --no-keep <program>",
        .run => "poof <program>",
        .enter => "poof, with no command",
    };
    print("\n  {s}deprecated{s} — the same thing with flags: {s}{s}{s}\n", .{ Y, R, C, replacement, R });

    switch (mode) {
        .exec => {
            print("\n{s}poof exec{s} — Run command in ephemeral sandbox {s}(changes vanish){s}\n", .{ C, R, D, R });
            print("\n{s}USAGE{s}\n", .{ B, R });
            print("  poof exec [options] [--] {s}<program>{s} [args...]\n", .{ Y, R });
            print("\n{s}EXAMPLES{s}\n", .{ B, R });
            print("  {s}${s} poof exec claude --dangerously-skip-permissions\n", .{ D, R });
            print("  {s}${s} poof exec rm -rf ~                 {s}# Safe! Nothing happens{s}\n", .{ D, R, D, R });
            print("  {s}${s} poof exec bash                    {s}# Disposable shell{s}\n", .{ D, R, D, R });
            print("  {s}${s} poof exec --timeout=60 ./build.sh  {s}# Kill if > 60s{s}\n", .{ D, R, D, R });
            print("\n{s}OPTIONS{s}\n", .{ B, R });
            print("  {s}--timeout=<secs>{s}    Kill after N seconds (exit code 124)\n", .{ G, R });
            print("  {s}--memory=<size>{s}     Memory limit (e.g. 100M, 1G)\n", .{ G, R });
            print("  {s}--pids=<max>{s}        Max processes (fork bomb protection)\n", .{ G, R });
            print("  {s}-v, --verbose{s}       Show detailed progress\n\n", .{ G, R });
        },
        .run => {
            print("\n{s}poof run{s} — Run command, review changes, apply or discard\n", .{ C, R });
            print("\n{s}USAGE{s}\n", .{ B, R });
            print("  poof run [options] [--] {s}<program>{s} [args...]\n", .{ Y, R });
            print("\n{s}EXAMPLES{s}\n", .{ B, R });
            print("  {s}${s} poof run claude --dangerously-skip-permissions\n", .{ D, R });
            print("  {s}${s} poof run bun install              {s}# Review changes first{s}\n", .{ D, R, D, R });
            print("  {s}${s} poof run --upper=./changes bash   {s}# keep the changes there{s}\n", .{ D, R, D, R });
            print("\n{s}When the command exits, you'll see:{s}\n", .{ D, R });
            print("  {s}poof{s}: {s}3 changed files{s} /tmp/poof-xxx\n", .{ BB, R, B, R });
            print("    {s}+{s} src/new-file.txt\n", .{ G, R });
            print("    {s}~{s} src/modified.txt\n", .{ Y, R });
            print("    {s}-{s} src/deleted.txt\n", .{ RE, R });
            print("\n  {s}Apply changes?{s} [y/N/d]\n", .{ Y, R });
            print("    {s}y{s} — Apply all changes to host\n", .{ G, R });
            print("    {s}n{s} — Discard (keep in temp dir)\n", .{ G, R });
            print("    {s}d{s} — Show full diff first\n", .{ G, R });
            print("\n{s}OPTIONS{s}\n", .{ B, R });
            print("  {s}--keep=<dir>{s}        Keep changes in <dir>, skip the prompt\n", .{ G, R });
            print("  {s}--yes{s}             Apply them to the host as the command exits\n", .{ G, R });
            print("  {s}--timeout=<secs>{s}    Kill after N seconds\n", .{ G, R });
            print("  {s}--memory=<size>{s}     Memory limit (e.g. 100M, 1G)\n", .{ G, R });
            print("  {s}--pids=<max>{s}        Max processes\n", .{ G, R });
            print("  {s}-v, --verbose{s}       Show detailed progress\n\n", .{ G, R });
        },
        .enter => {
            print("\n{s}poof enter{s} — Interactive sandbox with $SHELL\n", .{ C, R });
            print("\n{s}USAGE{s}\n", .{ B, R });
            print("  poof enter [options] [directory]\n", .{});
            print("\n{s}Opens your shell in an isolated environment.{s}\n", .{ D, R });
            print("{s}When you exit, review changes and apply or discard.{s}\n", .{ D, R });
            print("\n{s}EXAMPLES{s}\n", .{ B, R });
            print("  {s}${s} poof enter                        {s}# Sandbox current dir{s}\n", .{ D, R, D, R });
            print("  {s}${s} poof enter /etc                   {s}# Sandbox /etc{s}\n", .{ D, R, D, R });
            print("  {s}${s} cd myproject && poof enter        {s}# Edit safely{s}\n", .{ D, R, D, R });
            print("\n{s}OPTIONS{s}\n", .{ B, R });
            print("  {s}-v, --verbose{s}       Show detailed progress\n", .{ G, R });
            print("  {s}--timeout=<secs>{s}    Kill after N seconds\n", .{ G, R });
            print("  {s}--memory=<size>{s}     Memory limit (e.g. 100M, 1G)\n", .{ G, R });
            print("  {s}--pids=<max>{s}        Max processes\n\n", .{ G, R });
        },
    }
}

fn printUsage() void {
    const B = col(Color.bold);
    const C = col(Color.cyan);
    const M = col(Color.magenta);
    const G = col(Color.green);
    const Y = col(Color.yellow);
    const D = col(Color.dim);
    const R = col(Color.reset);

    // Banner
    print(
        \\
        \\{s} ▗▄▄▖  ▗▄▖  ▗▄▖ ▗▄▄▄▖{s}
        \\{s} ▐▌ ▐▌▐▌ ▐▌▐▌ ▐▌▐▌   {s}
        \\{s} ▐▛▀▘ ▐▌ ▐▌▐▌ ▐▌▐▛▀▀▘{s}
        \\{s} ▐▌   ▝▚▄▞▘▝▚▄▞▘▐▌   {s}
        \\{s}  Ephemeral filesystem isolation{s}
        \\
        \\
    , .{ M, R, M, R, M, R, M, R, D, R });

    // Usage & Commands
    print(
        \\{s}USAGE{s}
        \\  {s}poof{s} [options] [--] {s}<program>{s} {s}[args...]{s}
        \\  {s}poof{s} [options]                     {s}interactive shell{s}
        \\
        \\{s}CHANGES{s}
        \\  poof never writes to the real directory unless you say so. These flags
        \\  decide what happens to the changes a command makes:
        \\    {s}(default){s}      keep them in a /tmp stash, replay with {s}poof apply{s}
        \\    {s}--no-keep{s}      destroy them when the command exits
        \\    {s}--keep=<dir>{s}   keep them in <dir> instead of a /tmp stash
        \\    {s}--yes{s}          apply them to the real directory as the command exits
        \\
    , .{ B, R, C, R, Y, R, G, R, C, R, D, R, B, R, C, R, D, R, C, R, C, R, C, R });

    // Subcommands, and the mode words that are no longer needed
    print(
        \\
        \\{s}COMMANDS{s}
        \\  {s}apply{s} <stash>              Replay a saved stash onto the host
        \\  {s}stash{s} list                 List stashes left in /tmp
        \\  {s}exec{s} / {s}run{s} / {s}enter{s}         Deprecated mode words, still accepted
        \\
    , .{ B, R, C, R, C, R, C, R, C, R, C, R });

    // Options
    print(
        \\{s}OPTIONS{s}
        \\  {s}-v, --verbose{s}               Show detailed progress
        \\  {s}-h, --help{s}                  Show this help
        \\  {s}-V, --version{s}               Show version
        \\  {s}--timeout=<secs>{s}            Kill after N seconds {s}(exit code 124){s}
        \\  {s}--memory=<bytes>{s}            Memory limit {s}(e.g. 100M, 1G){s}
        \\  {s}--pids=<max>{s}                Max processes {s}(fork bomb protection){s}
        \\  {s}--upper=<dir>{s}               Deprecated: use {s}--keep=<dir>{s}
        \\
    , .{ B, R, G, R, G, R, G, R, G, R, D, R, G, R, D, R, G, R, D, R, G, R, G, R });

    // Isolation
    print(
        \\{s}ISOLATION{s}
        \\  {s}•{s} Mount namespace with overlay filesystem
        \\  {s}•{s} PID namespace {s}(isolated process tree){s}
        \\  {s}•{s} UTS namespace {s}(isolated hostname){s}
        \\  {s}•{s} IPC namespace {s}(isolated System V IPC){s}
        \\
    , .{ B, R, M, R, M, R, D, R, M, R, D, R, M, R, D, R });

    // Examples
    print(
        \\{s}EXAMPLES{s}
        \\  {s}${s} poof bun install              {s}# kept; replay with poof apply{s}
        \\  {s}${s} poof --yes make               {s}# applied as soon as it exits{s}
        \\  {s}${s} poof --no-keep rm -rf ~       {s}# Safe! Nothing happens{s}
        \\  {s}${s} poof                          {s}# a shell, reviewed on exit{s}
        \\
    , .{ B, R, D, R, D, R, D, R, D, R, D, R, D, R, D, R, D, R });

    print(
        \\{s}NOTE{s}  Works inside Docker/Podman {s}(1 nesting level, kernel limit){s}
        \\{s}ENV{s}   IS_SANDBOX=1 is set inside the sandbox
        \\
        \\
    , .{ Y, R, D, R, G, R });
}

pub fn main(init: std.process.Init.Minimal) u8 {
    output.init();

    const args = std.process.Args.toSlice(init.args, allocator) catch {
        err("out of memory", .{});
        return 1;
    };

    var cwd_buf: [4096]u8 = undefined;
    const cwd = getHostCwd(&cwd_buf);

    var config = Config{
        .command = &.{},
        .cwd = cwd,
    };

    var keep_dir: ?[]const u8 = null;
    var used_upper = false;
    var no_keep = false;
    var alias: ?Alias = null;
    var sub: ?Subcommand = null;
    var apply_opt: ?[]const u8 = null;
    var assume_yes = false;
    var cmd_start: usize = args.len;
    var sub_arg: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            // Help is the requested result, so it goes to stdout (exit 0).
            output.routeToStdout(true);
            if (sub != null and sub.? == .apply) printApplyHelp() else if (alias) |a| printModeHelp(a) else printUsage();
            output.routeToStdout(false);
            return 0;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            output.routeToStdout(true);
            printVersion();
            output.routeToStdout(false);
            return 0;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            output.setVerbose(true);
        } else if (std.mem.startsWith(u8, arg, "--keep=")) {
            keep_dir = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--upper=")) {
            // The old name for --keep: it named the overlay mechanism, not the intent.
            keep_dir = arg[8..];
            used_upper = true;
        } else if (std.mem.eql(u8, arg, "--no-keep")) {
            no_keep = true;
        } else if (std.mem.startsWith(u8, arg, "--apply=")) {
            if (arg[8..].len == 0) {
                err("invalid apply: (use --apply=<stash dir>)", .{});
                return 1;
            }
            apply_opt = arg[8..];
            sub = .apply;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            assume_yes = true;
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            const secs = std.fmt.parseInt(u32, arg[10..], 10) catch {
                err("invalid timeout: {s}", .{arg[10..]});
                return 1;
            };
            if (secs == 0) {
                err("invalid timeout: 0 (use --timeout=<secs> with secs > 0)", .{});
                return 1;
            }
            config.timeout = secs;
        } else if (std.mem.startsWith(u8, arg, "--memory=")) {
            const bytes = parseSize(arg[9..]) catch {
                err("invalid memory limit: {s} (use e.g. 100M, 1G)", .{arg[9..]});
                return 1;
            };
            if (bytes == 0) {
                err("invalid memory limit: 0 (use --memory=<size> with size > 0)", .{});
                return 1;
            }
            config.memory_limit = bytes;
        } else if (std.mem.startsWith(u8, arg, "--pids=")) {
            const max = std.fmt.parseInt(u32, arg[7..], 10) catch {
                err("invalid pids limit: {s}", .{arg[7..]});
                return 1;
            };
            if (max == 0) {
                err("invalid pids limit: 0 (must be at least 1)", .{});
                return 1;
            }
            if (max < 2) {
                // The sandbox always needs more than one process in the cgroup:
                // the namespace init plus the command it runs.
                err("invalid pids limit: {d} (the sandbox needs at least 2 processes)", .{max});
                return 1;
            }
            config.pids_limit = max;
        } else if (std.mem.eql(u8, arg, "--")) {
            cmd_start = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "exec")) {
            alias = .exec;
        } else if (std.mem.eql(u8, arg, "run")) {
            alias = .run;
        } else if (std.mem.eql(u8, arg, "enter")) {
            alias = .enter;
        } else if (std.mem.eql(u8, arg, "apply") and alias == null) {
            // Only a subcommand while no mode word precedes it, so `poof exec apply`
            // still runs a program called apply.
            sub = .apply;
        } else if (std.mem.eql(u8, arg, "stash") and alias == null) {
            sub = .stash;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (sub != null) {
                // Subcommands take at most one positional, but options may still
                // follow it (poof apply <stash> --yes).
                if (sub_arg != null) {
                    err("too many arguments: {s}", .{arg});
                    return 1;
                }
                sub_arg = arg;
                continue;
            }
            cmd_start = i;
            break;
        } else {
            err("unknown option: {s}", .{arg});
            return 1;
        }
    }

    // Subcommands work on a previous session's stash; they never start a sandbox.
    if (sub) |s| {
        if (no_keep or keep_dir != null) warn("--keep/--no-keep configure a session; ignored for a subcommand", .{});
        switch (s) {
            .apply => {
                const target = apply_opt orelse sub_arg;
                if (target == null) {
                    err("apply needs a stash directory: poof apply <stash>", .{});
                    return 1;
                }
                if (apply_opt != null and sub_arg != null) {
                    err("apply takes no command: {s}", .{sub_arg.?});
                    return 1;
                }
                return applyStash(target.?, cwd, assume_yes);
            },
            .stash => {
                const what = sub_arg orelse "list";
                if (std.mem.eql(u8, what, "list")) return listStashes();
                err("unknown stash subcommand: {s} (try: poof stash list)", .{what});
                return 1;
            },
        }
    }

    // Deprecation notices for the old mode words. They come after the parse loop so
    // that --help and --version stay clean on stdout.
    if (alias) |a| {
        switch (a) {
            .exec => warn("'poof exec' is deprecated: poof --no-keep <program> does this", .{}),
            .run => warn("'poof run' is deprecated: poof <program> does this", .{}),
            .enter => warn("'poof enter' is deprecated: poof with no command does this", .{}),
        }
    }
    if (used_upper) warn("--upper is deprecated: use --keep=<dir>", .{});

    // Axis one: what happens to the changes once the session ends.
    if (no_keep and keep_dir != null) {
        err("--keep and --no-keep conflict: --keep=<dir> stores the changes, --no-keep destroys them", .{});
        return 1;
    }
    config.keep = if (no_keep) .none else if (keep_dir != null) .dir else .auto;

    // `poof enter <dir>` took a directory where every other form takes a command. That
    // quirk survives only with the deprecated word; the plain form is `cd <dir> && poof`.
    var enter_dir: ?[]const u8 = null;
    if (alias == .enter and cmd_start < args.len) {
        if (cmd_start + 1 < args.len) {
            err("enter takes at most one directory, got extra argument: {s}", .{args[cmd_start + 1]});
            return 1;
        }
        enter_dir = args[cmd_start];
        cmd_start = args.len; // consumed: it is a directory, not a command
    }

    if (cmd_start >= args.len) {
        // No command: the session is a shell. This is what `enter` used to name; the
        // disposition of the changes comes from the flags, not from the shell.
        const shell = if (std.c.getenv("SHELL")) |p| std.mem.span(p) else "/bin/sh";
        const shell_args = allocator.alloc([]const u8, 1) catch {
            err("out of memory", .{});
            return 1;
        };
        shell_args[0] = shell;
        config.command = shell_args;

        var target = cwd;
        if (enter_dir) |arg_dir| {
            target = if (arg_dir.len > 0 and arg_dir[0] == '/')
                arg_dir
            else if (std.mem.eql(u8, cwd, "/"))
                std.fmt.allocPrint(allocator, "/{s}", .{arg_dir}) catch {
                    err("out of memory", .{});
                    return 1;
                }
            else
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, arg_dir }) catch {
                    err("out of memory", .{});
                    return 1;
                };
            if (!sandbox.isDirectory(target)) {
                err("not a directory: {s}", .{target});
                return 1;
            }
        }
        config.cwd = target;
    } else {
        config.command = args[cmd_start..];
    }

    // Axis two: when the changes get replayed onto the host. A shell session is
    // interactive by nature, so it asks even when stdin is not a terminal; a scripted
    // command leaves its stash for `poof apply` instead, and --keep=<dir> means the
    // caller chose where the stash goes and will replay it by path.
    if (assume_yes and config.keep == .none) {
        err("--yes has nothing to apply: --no-keep destroys the changes", .{});
        return 1;
    }
    if (assume_yes and config.keep == .dir) {
        err("--yes and --keep=<dir> conflict: --keep already says where to apply the changes", .{});
        return 1;
    }
    config.apply_at_exit = if (config.keep == .none)
        .never
    else if (assume_yes)
        .always
    else if (config.keep == .dir)
        .never
    else if (cmd_start >= args.len or std.c.isatty(std.posix.STDIN_FILENO) == 1)
        .ask
    else
        .never;

    if (config.apply_at_exit != .never) {
        config.apply_target = config.cwd;
    }

    config.verbose = output.isVerbose();

    // Where the changes go.
    switch (config.keep) {
        .none => {}, // setupOverlay puts the upper on a tmpfs that dies with the namespace
        .dir => {
            const dir = keep_dir.?;
            if (dir.len > 0 and dir[0] != '/') {
                config.upper_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, dir }) catch {
                    err("out of memory", .{});
                    return 1;
                };
            } else {
                config.upper_dir = dir;
            }
        },
        .auto => {
            // A /tmp/poof-<hex> stash: the same place for a scripted run and a shell, so
            // `poof stash list` finds it either way. A session that will ask at exit
            // shows the change list there; one that will not gets the path and the
            // replay command up front.
            config.upper_dir = sandbox.makeTempDir() catch |e| {
                err("cannot create stash directory: {}", .{e});
                return 1;
            };
            if (config.apply_at_exit == .never) {
                const hc = col(Color.bold ++ Color.cyan);
                const rc = col(Color.reset);
                info("Changes will be kept in {s}{s}{s}", .{ hc, config.upper_dir.?, rc });
                info("replay them with: poof apply {s}", .{config.upper_dir.?});
            }
        },
    }

    return run(config);
}
