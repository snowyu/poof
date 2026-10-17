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

// Re-exports from modules
const allocator = sandbox.allocator;
const Config = sandbox.Config;
const Mode = sandbox.Mode;

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

fn generateTimestamp() ![]const u8 {
    const secs: u64 = @intCast(clockSecs(posix.CLOCK.REALTIME) orelse return error.ClockError);
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getDaySeconds();
    const yd = epoch.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();

    return try std.fmt.allocPrint(allocator, "{d}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
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
    // Forward signal to child and wait for it to exit
    if (child_pid > 0) {
        _ = linux.kill(child_pid, sig);
        // Wait for child to exit so mounts are cleaned up
        var status: i32 = 0;
        _ = linux.waitpid(child_pid, &status, 0);
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

// A directory the sandbox created is marked opaque: its contents replace the
// target directory's contents entirely. readdir hands the marker back in
// arbitrary order, so it has to be looked for before the contents are replayed.
fn hasOpaqueMarker(src_dir: []const u8) bool {
    var dir = sandbox.DirStream.open(src_dir) orelse return false;
    defer dir.close();
    while (dir.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".wh..wh..opq") or std.mem.eql(u8, entry.name, ".wh..opq")) return true;
    }
    return false;
}

fn isWhiteout(entry_kind: sandbox.DirEntryKind, stat: ?FileInfo) bool {
    if (stat) |fi| {
        if (fi.is_char) return fi.is_whiteout_dev;
        return false;
    }
    // statx unavailable (pre-4.11 kernel): fall back to the dirent type.
    return entry_kind == .character_device;
}

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
            // Whiteout - file was deleted
            const is_marker = blk: {
                if (whiteoutName(entry.name) != null) break :blk true;
                const src_z = zPath(full_path) orelse break :blk true;
                const fi = fileInfo(src_z) orelse break :blk true;
                break :blk fi.is_whiteout_dev;
            };
            if (is_marker) {
                changes.append(.{ .path = display_path, .change_type = .deleted });
            } else {
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

// Handle enter mode - show changes and prompt to apply
fn handleEnterModeChanges(config: Config) void {
    const upper_dir = config.upper_dir orelse return;
    const target_dir = config.enter_target orelse return;

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
        _ = sandbox.runProcess(&full_diff_argv);

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

// An interactive session that was killed (timeout/signal) never got to prompt,
// so keep its upper dir and tell the user where to find it.
fn stashInteractiveChanges() void {
    const upper_dir = interactive_upper orelse return;
    const changes_path = interactive_changes_path orelse return;
    if (hasDirEntries(changes_path)) keepChanges(upper_dir);
}

fn keepChanges(upper_dir: []const u8) void {
    // Don't delete the temp dir - user wants to keep it
    sandbox.cleanup_temp_base = null;
    sandbox.cleanup_work_dir = null;
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

    if (hasOpaqueMarker(src_dir)) clearDir(dst_dir, stats);

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

        if (isWhiteout(entry.kind, fi)) {
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

pub fn run(config: Config) u8 {
    const orig_uid = linux.getuid();
    const orig_gid = linux.getgid();

    // Show startup info (minimal unless verbose)
    if (config.mode == .exec) {
        vstep("Starting ephemeral environment", .{});
    } else if (config.enter_target != null) {
        // Interactive mode (enter or run without --upper)
        vstep("Entering poof mode for {s}", .{config.enter_target.?});
    } else {
        vstep("Starting persistent environment", .{});
    }
    log("uid={} gid={}", .{ orig_uid, orig_gid });

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
    if (config.mode == .exec) {
        // For exec: create temp dir now so parent knows the path to clean up
        sandbox.cleanup_temp_base = sandbox.makeTempDir() catch |e| {
            err("makeTempDir: {}", .{e});
            return 1;
        };
    } else if (config.mode == .run or config.mode == .enter) {
        // For run/enter: .work sits next to the user's upper dir (kernel overlay wants
        // upper and work on one filesystem); the merged mount point goes into a private
        // temp base so it stays invisible from inside the sandbox.
        sandbox.cleanup_work_dir = std.fmt.allocPrint(allocator, "{s}.work", .{config.upper_dir.?}) catch null;
        sandbox.cleanup_merged_base = sandbox.makeTempDir() catch |e| {
            err("makeTempDir: {}", .{e});
            return 1;
        };
        // For enter mode (and interactive run), also clean up the temp upper dir
        if (config.enter_target != null) {
            sandbox.cleanup_temp_base = config.upper_dir;
        }
    }

    // Remember what an abnormal exit must stash (interactive run/enter only)
    if (config.enter_target != null) {
        interactive_upper = config.upper_dir;
        interactive_changes_path = std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ config.upper_dir.?, config.enter_target.? },
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

            // Handle interactive mode - prompt to apply changes before cleanup
            if (config.enter_target != null) {
                handleEnterModeChanges(config);
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
    if (git_commit.len > 0) {
        print("poof {s} ({s})\n", .{ version, git_commit });
    } else {
        print("poof {s}\n", .{version});
    }
}

fn printModeHelp(mode: sandbox.Mode) void {
    const C = col(Color.cyan);
    const B = col(Color.bold);
    const BB = col(Color.bold_blue);
    const G = col(Color.green);
    const Y = col(Color.yellow);
    const RE = col(Color.red);
    const D = col(Color.dim);
    const R = col(Color.reset);

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
            print("  {s}${s} poof run --upper=./changes bash   {s}# Persist to ./changes/{s}\n", .{ D, R, D, R });
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
            print("  {s}--upper=<dir>{s}       Save changes to directory (skip prompt)\n", .{ G, R });
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
        \\  {s}poof{s} {s}<command>{s} [options] [--] {s}<program>{s} [args...]
        \\
        \\{s}COMMANDS{s}
        \\  {s}exec{s}  <program>             Run in ephemeral mode {s}(changes vanish){s}
        \\  {s}run{s}   <program>             Review & apply on exit {s}(or --upper to persist){s}
        \\  {s}enter{s}                       Interactive $SHELL {s}(review & apply on exit){s}
        \\
    , .{ B, R, C, R, Y, R, G, R, B, R, C, R, D, R, C, R, D, R, C, R, D, R });

    // Options
    print(
        \\{s}OPTIONS{s}
        \\  {s}-v, --verbose{s}               Show detailed progress
        \\  {s}-h, --help{s}                  Show this help
        \\  {s}-V, --version{s}               Show version
        \\  {s}--upper=<dir>{s}               Directory for changes {s}(run mode){s}
        \\  {s}--timeout=<secs>{s}            Kill after N seconds
        \\  {s}--memory=<bytes>{s}            Memory limit {s}(e.g. 100M, 1G){s}
        \\  {s}--pids=<max>{s}                Max processes {s}(fork bomb protection){s}
        \\
    , .{ B, R, G, R, G, R, G, R, G, R, D, R, G, R, G, R, D, R, G, R, D, R });

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
        \\  {s}${s} poof exec claude --dangerously-skip-permissions
        \\  {s}${s} poof exec rm -rf ~                {s}# Safe! Nothing happens{s}
        \\  {s}${s} poof run bun install              {s}# Review changes first{s}
        \\
        \\{s}NOTE{s}  Works inside Docker/Podman {s}(1 nesting level, kernel limit){s}
        \\{s}ENV{s}   IS_SANDBOX=1 is set inside the sandbox
        \\
        \\
    , .{ B, R, D, R, D, R, D, R, D, R, D, R, Y, R, D, R, G, R });
}

pub fn main(init: std.process.Init.Minimal) u8 {
    output.init();

    const args = std.process.Args.toSlice(init.args, allocator) catch {
        err("out of memory", .{});
        return 1;
    };

    // No args = enter mode (interactive shell)
    if (args.len < 2) {
        // Fall through to enter mode below
    }

    var cwd_buf: [4096]u8 = undefined;
    const cwd = getHostCwd(&cwd_buf);

    var config = Config{
        .mode = .exec,
        .command = &.{},
        .cwd = cwd,
    };

    var upper_dir: ?[]const u8 = null;
    var mode: ?Mode = null;
    var cmd_start: usize = args.len;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            // Help is the requested result, so it goes to stdout (exit 0).
            output.routeToStdout(true);
            if (mode) |m| printModeHelp(m) else printUsage();
            output.routeToStdout(false);
            return 0;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            output.routeToStdout(true);
            printVersion();
            output.routeToStdout(false);
            return 0;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            output.setVerbose(true);
        } else if (std.mem.startsWith(u8, arg, "--upper=")) {
            upper_dir = arg[8..];
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
            mode = .exec;
        } else if (std.mem.eql(u8, arg, "run")) {
            mode = .run;
        } else if (std.mem.eql(u8, arg, "enter")) {
            mode = .enter;
        } else if (arg.len > 0 and arg[0] != '-') {
            cmd_start = i;
            break;
        } else {
            err("unknown option: {s}", .{arg});
            return 1;
        }
    }

    if (mode == null) {
        // Check if first arg is a known shell - treat as `poof exec <shell>`
        if (cmd_start < args.len) {
            const first_cmd = args[cmd_start];
            // Get basename of command
            const basename = if (std.mem.lastIndexOfScalar(u8, first_cmd, '/')) |idx|
                first_cmd[idx + 1 ..]
            else
                first_cmd;

            if (std.mem.eql(u8, basename, "bash") or
                std.mem.eql(u8, basename, "zsh") or
                std.mem.eql(u8, basename, "fish") or
                std.mem.eql(u8, basename, "sh"))
            {
                mode = .exec;
            }
        }

        // Default to enter mode (interactive shell)
        if (mode == null) {
            mode = .enter;
        }
    }

    config.mode = mode.?;
    config.verbose = output.isVerbose();

    // --upper only means anything for run mode; say so instead of dropping it.
    if (upper_dir != null and config.mode != .run) {
        warn("--upper is only used by run mode; ignored for {s} mode", .{@tagName(config.mode)});
    }

    // Handle enter mode specially - uses $SHELL, no command needed
    if (config.mode == .enter) {
        const shell = if (std.c.getenv("SHELL")) |p| std.mem.span(p) else "/bin/sh";
        const shell_args = allocator.alloc([]const u8, 1) catch {
            err("out of memory", .{});
            return 1;
        };
        shell_args[0] = shell;
        config.command = shell_args;

        // `poof enter <directory>` — sandbox that directory instead of the cwd.
        var target = cwd;
        if (cmd_start < args.len) {
            if (cmd_start + 1 < args.len) {
                err("enter takes at most one directory, got extra argument: {s}", .{args[cmd_start + 1]});
                return 1;
            }
            const arg_dir = args[cmd_start];
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
        config.enter_target = target;
        config.cwd = target;

        // Create temp upper dir for enter mode
        config.upper_dir = sandbox.makeTempDir() catch {
            err("failed to create temp dir", .{});
            return 1;
        };
    } else {
        if (cmd_start >= args.len) {
            printModeHelp(config.mode);
            return 1;
        }
        config.command = args[cmd_start..];
    }

    // Determine upper directory for run mode
    if (config.mode == .run) {
        const is_interactive = std.c.isatty(std.posix.STDIN_FILENO) == 1;

        if (upper_dir) |dir| {
            // --upper explicitly provided: persist changes there
            if (dir.len > 0 and dir[0] != '/') {
                config.upper_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, dir }) catch {
                    err("out of memory", .{});
                    return 1;
                };
            } else {
                config.upper_dir = dir;
            }
        } else if (is_interactive) {
            // Interactive mode without --upper: use temp dir and prompt y/n/d on exit
            config.upper_dir = sandbox.makeTempDir() catch {
                err("failed to create temp dir", .{});
                return 1;
            };
            config.enter_target = cwd; // Triggers y/n/d prompt on exit
        } else {
            // Non-interactive without --upper: auto-generate from command name
            const cmd_name = std.fs.path.basename(config.command[0]);
            const base_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, cmd_name }) catch {
                err("out of memory", .{});
                return 1;
            };

            // Check if base path exists, if so append timestamp
            if (sandbox.pathExists(base_path)) {
                const ts = generateTimestamp() catch {
                    err("clock error", .{});
                    return 1;
                };
                config.upper_dir = std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_path, ts }) catch {
                    err("out of memory", .{});
                    return 1;
                };
            } else {
                config.upper_dir = base_path;
            }

            const hc = col(Color.bold ++ Color.cyan);
            const rc = col(Color.reset);
            info("Changes will persist to {s}{s}{s}", .{ hc, config.upper_dir.?, rc });
        }
    }

    return run(config);
}
