const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = std.c;
const output = @import("output.zig");

// C library functions for environment and program execution
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

// Re-export output functions for convenience
pub const step = output.step;
pub const vstep = output.vstep;
pub const success = output.success;
pub const log = output.log;
pub const err = output.err;
pub const warn = output.warn;
pub const info = output.info;
pub const col = output.col;
pub const print = output.print;
pub const Color = output.Color;

// Use C allocator - no leak detection issues after fork
pub const allocator = std.heap.c_allocator;

pub const Errno = linux.E;

pub fn Maybe(comptime T: type) type {
    return union(enum) {
        err: Errno,
        ok: T,
    };
}

pub fn errnoFromSyscall(r: usize) Errno {
    const signed_r: isize = @bitCast(r);
    const int: u16 = if (signed_r > -4096 and signed_r < 0) @intCast(-signed_r) else 0;
    return @fromBackingInt(@intCast(int));
}

pub const Mode = enum {
    exec, // tmpfs overlay - ephemeral, changes vanish
    run, // persistent upper dir, changes saved
    enter, // interactive - run $SHELL, prompt to apply changes on exit
};

pub const Config = struct {
    mode: Mode,
    command: []const []const u8,
    upper_dir: ?[]const u8 = null,
    verbose: bool = false,
    cwd: []const u8 = "/",
    // Resource limits (cgroups v2)
    memory_limit: ?u64 = null, // bytes
    pids_limit: ?u32 = null, // max processes
    // Timeout
    timeout: ?u32 = null, // seconds
    // For enter mode: track the target directory to apply changes to
    enter_target: ?[]const u8 = null,
};

// ============================================================================
// Syscall Wrappers
// ============================================================================

pub fn mount(source: [*:0]const u8, target: [*:0]const u8, fstype: [*:0]const u8, flags: u32, data: ?[*:0]const u8) Maybe(void) {
    const data_ptr: usize = if (data) |d| @intFromPtr(d) else 0;
    const result = linux.mount(source, target, fstype, flags, data_ptr);
    const e = errnoFromSyscall(result);
    if (e != .SUCCESS) {
        log("mount failed: source={s} target={s} fstype={s} errno={}", .{ source, target, fstype, e });
        return .{ .err = e };
    }
    return .{ .ok = {} };
}

pub fn umount2(target: [*:0]const u8, flags: u32) Maybe(void) {
    const result = linux.umount2(target, flags);
    const e = errnoFromSyscall(result);
    if (e != .SUCCESS) return .{ .err = e };
    return .{ .ok = {} };
}

pub fn pivotRoot(new_root: [*:0]const u8, put_old: [*:0]const u8) Maybe(void) {
    const result = linux.pivot_root(new_root, put_old);
    const e = errnoFromSyscall(result);
    if (e != .SUCCESS) {
        log("pivot_root failed: errno={}", .{e});
        return .{ .err = e };
    }
    return .{ .ok = {} };
}

// ---------------------------------------------------------------------------
// Filesystem helpers
//
// Zig 0.17 moved std.fs behind the std.Io interface, which is not usable from
// the forked child of a sandbox (the Io implementation's helper threads do not
// survive fork). These helpers use plain syscalls instead.
// ---------------------------------------------------------------------------

pub const FsError = error{
    FileNotFound,
    AccessDenied,
    PermissionDenied,
    PathAlreadyExists,
    NotDir,
    IsDir,
    DirNotEmpty,
    NameTooLong,
    OutOfMemory,
    InputOutput,
    NoSpaceLeft,
    Unexpected,
};

fn fsError(e: Errno) FsError {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .EXIST => error.PathAlreadyExists,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .NOTEMPTY => error.DirNotEmpty,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.OutOfMemory,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        else => error.Unexpected,
    };
}

pub fn openForRead(path: []const u8) FsError!posix.fd_t {
    const p = posix.toPosixPath(path) catch return error.NameTooLong;
    const fd = linux.open(&p, .{}, 0);
    const e = errnoFromSyscall(fd);
    if (e != .SUCCESS) return fsError(e);
    return @intCast(fd);
}

pub fn readFd(fd: posix.fd_t, buf: []u8) FsError!usize {
    const n = linux.read(fd, buf.ptr, buf.len);
    const e = errnoFromSyscall(n);
    if (e != .SUCCESS) return fsError(e);
    return n;
}

pub fn readFile(path: []const u8, buf: []u8) FsError!usize {
    const fd = try openForRead(path);
    defer _ = linux.close(fd);
    return readFd(fd, buf);
}

pub fn writeFile(path: []const u8, content: []const u8) FsError!void {
    const p = posix.toPosixPath(path) catch return error.NameTooLong;
    // Write-only, no create/truncate: these are procfs and cgroup attribute files.
    const fd = linux.open(&p, .{ .ACCMODE = .WRONLY }, 0);
    const e = errnoFromSyscall(fd);
    if (e != .SUCCESS) return fsError(e);
    const handle: posix.fd_t = @intCast(fd);
    defer _ = linux.close(handle);

    var written: usize = 0;
    while (written < content.len) {
        const n = linux.write(handle, content[written..].ptr, content.len - written);
        const we = errnoFromSyscall(n);
        if (we != .SUCCESS) return fsError(we);
        written += n;
    }
}

pub fn makeDirPath(path: []const u8) FsError!void {
    const p = posix.toPosixPath(path) catch return error.NameTooLong;
    const e = errnoFromSyscall(linux.mkdir(&p, 0o755));
    if (e != .SUCCESS) return fsError(e);
}

pub fn deleteDirPath(path: []const u8) FsError!void {
    const p = posix.toPosixPath(path) catch return error.NameTooLong;
    const e = errnoFromSyscall(linux.rmdir(&p));
    if (e != .SUCCESS) return fsError(e);
}

pub fn createFilePath(path: []const u8) FsError!void {
    const p = posix.toPosixPath(path) catch return error.NameTooLong;
    const fd = linux.open(&p, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o666);
    const e = errnoFromSyscall(fd);
    if (e != .SUCCESS) return fsError(e);
    _ = linux.close(@intCast(fd));
}

pub fn pathExists(path: []const u8) bool {
    const p = posix.toPosixPath(path) catch return false;
    return errnoFromSyscall(linux.access(&p, posix.F_OK)) == .SUCCESS;
}

pub const DirEntryKind = enum { file, directory, character_device, other };

pub const DirEntry = struct {
    name: []const u8,
    kind: DirEntryKind,
};

/// Directory stream backed by libc opendir/readdir (no std.Io required).
pub const DirStream = struct {
    handle: *c.DIR,

    pub fn open(path: []const u8) ?DirStream {
        const p = posix.toPosixPath(path) catch return null;
        const handle = c.opendir(&p) orelse return null;
        return .{ .handle = handle };
    }

    pub fn next(self: *DirStream) ?DirEntry {
        while (c.readdir(self.handle)) |d| {
            const name = std.mem.sliceTo(&d.name, 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const kind: DirEntryKind = switch (d.type) {
                posix.DT.DIR => .directory,
                posix.DT.CHR => .character_device,
                posix.DT.REG => .file,
                else => .other,
            };
            return .{ .name = name, .kind = kind };
        }
        return null;
    }

    pub fn close(self: *DirStream) void {
        _ = c.closedir(self.handle);
    }
};

/// Best-effort recursive delete (replaces fs.deleteTreeAbsolute).
pub fn deleteTree(path: []const u8) void {
    if (DirStream.open(path)) |dir_handle| {
        var dir = dir_handle;
        defer dir.close();
        while (dir.next()) |entry| {
            const child = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name }) catch return;
            deleteTree(child);
        }
    }
    deleteDirPath(path) catch {
        const p = posix.toPosixPath(path) catch return;
        _ = linux.unlink(&p);
    };
}

/// Best-effort sleep (replaces the removed posix.nanosleep).
pub fn sleepNs(seconds: i64, nanoseconds: i64) void {
    const req = posix.timespec{ .sec = seconds, .nsec = nanoseconds };
    _ = linux.nanosleep(&req, null);
}

/// Random bytes from the kernel (replaces std.crypto.random).
fn randomBytes(buf: []u8) void {
    const n = linux.getrandom(buf.ptr, buf.len, 0);
    if (errnoFromSyscall(n) == .SUCCESS) return;
    // Fall back to time-based entropy if getrandom is unavailable.
    var ts = posix.timespec{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
    const seed: u64 = @as(u64, @bitCast(ts.sec ^ ts.nsec)) ^ @as(u64, @intFromPtr(buf.ptr));
    var state = seed;
    for (buf) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 33);
    }
}

/// Run a program (resolved via PATH) and wait for it, inheriting stdio.
/// Returns the exit code, or null if the process could not be started.
pub fn runProcess(argv: []const []const u8) ?u8 {
    const argvz = allocator.allocSentinel(?[*:0]const u8, argv.len, null) catch return null;
    for (argv, 0..) |arg, i| {
        argvz[i] = (allocator.dupeSentinel(u8, arg, 0) catch return null).ptr;
    }

    const pid = linux.fork();
    if (pid == 0) {
        _ = execvp(argvz[0].?, argvz.ptr);
        c._exit(127);
    } else if (pid > 0) {
        var status: i32 = 0;
        const waited = linux.waitpid(@intCast(pid), &status, 0);
        if (errnoFromSyscall(waited) != .SUCCESS) return null;
        const us: u32 = @bitCast(status);
        if (linux.W.IFEXITED(us)) return linux.W.EXITSTATUS(us);
        return 1;
    }
    return null;
}

// ============================================================================
// User Namespace Setup
// ============================================================================

pub fn setupUidGidMappings(uid: u32, gid: u32) !void {
    var buf: [64]u8 = undefined;

    const uid_content = try std.fmt.bufPrint(&buf, "0 {d} 1\n", .{uid});
    try writeFile("/proc/self/uid_map", uid_content);
    try writeFile("/proc/self/setgroups", "deny");
    const gid_content = try std.fmt.bufPrint(&buf, "0 {d} 1\n", .{gid});
    try writeFile("/proc/self/gid_map", gid_content);
}

// ============================================================================
// Cleanup State
// ============================================================================

// Cleanup paths (set during setupOverlay, cleaned by parent after child exits)
pub var cleanup_temp_base: ?[]const u8 = null; // exec/enter mode: temp dir to delete
pub var cleanup_work_dir: ?[]const u8 = null; // run mode: .work dir to delete
pub var cleanup_merged_dir: ?[]const u8 = null; // run mode: .merged dir to delete

pub fn cleanupOverlayDirs() void {
    // Delete temp base directory (exec and enter modes)
    if (cleanup_temp_base) |path| {
        deleteTree(path);
    }
    // Run mode: delete the .work and .merged directories we created
    if (cleanup_work_dir) |path| {
        deleteTree(path);
    }
    if (cleanup_merged_dir) |path| {
        deleteTree(path);
    }
}

// ============================================================================
// Cgroups v2 Setup
// ============================================================================

var cgroup_path: ?[]const u8 = null;
var original_cgroup: ?[]const u8 = null;

fn getOriginalCgroup() ?[]const u8 {
    var buf: [256]u8 = undefined;
    const n = readFile("/proc/self/cgroup", &buf) catch return null;
    const data = buf[0..n];
    // Format: "0::/path/to/cgroup\n"
    if (std.mem.indexOf(u8, data, "::")) |idx| {
        const path_start = idx + 2;
        const path_end = std.mem.indexOf(u8, data[path_start..], "\n") orelse (data.len - path_start);
        const cgroup_rel = data[path_start..][0..path_end];
        return std.fmt.allocPrint(allocator, "/sys/fs/cgroup{s}/cgroup.procs", .{cgroup_rel}) catch null;
    }
    return null;
}

pub fn setupCgroup(config: Config) !void {
    // Check if cgroups v2 is available
    if (!pathExists("/sys/fs/cgroup/cgroup.controllers")) {
        if (config.memory_limit != null or config.pids_limit != null) {
            return error.CgroupsNotAvailable;
        }
        return;
    }

    // Save original cgroup for cleanup
    original_cgroup = getOriginalCgroup();

    // Create unique cgroup
    var rand_buf: [8]u8 = undefined;
    randomBytes(&rand_buf);
    var suffix: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&suffix, "{x:0>16}", .{std.mem.readInt(u64, &rand_buf, .little)}) catch unreachable;
    cgroup_path = try std.fmt.allocPrint(allocator, "/sys/fs/cgroup/poof-{s}", .{suffix});

    makeDirPath(cgroup_path.?) catch |e| {
        log("failed to create cgroup: {}", .{e});
        return e;
    };

    var buf: [64]u8 = undefined;

    // Set memory limit
    if (config.memory_limit) |mem| {
        const path = try std.fmt.allocPrint(allocator, "{s}/memory.max", .{cgroup_path.?});
        const content = try std.fmt.bufPrint(&buf, "{d}", .{mem});
        writeFile(path, content) catch |e| {
            log("failed to set memory limit: {}", .{e});
        };
        log("cgroup memory.max={d}", .{mem});
    }

    // Set pids limit
    if (config.pids_limit) |pids| {
        const path = try std.fmt.allocPrint(allocator, "{s}/pids.max", .{cgroup_path.?});
        const content = try std.fmt.bufPrint(&buf, "{d}", .{pids});
        writeFile(path, content) catch |e| {
            log("failed to set pids limit: {}", .{e});
        };
        log("cgroup pids.max={d}", .{pids});
    }

    // Move current process into cgroup
    const procs_path = try std.fmt.allocPrint(allocator, "{s}/cgroup.procs", .{cgroup_path.?});
    const pid_content = try std.fmt.bufPrint(&buf, "{d}", .{linux.getpid()});
    try writeFile(procs_path, pid_content);

    log("cgroup created: {s}", .{cgroup_path.?});
}

pub fn cleanupCgroup() void {
    if (cgroup_path) |path| {
        // Move ourselves back to original cgroup first
        if (original_cgroup) |orig| {
            var buf: [32]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&buf, "{d}", .{linux.getpid()}) catch return;
            writeFile(orig, pid_str) catch {};
        }

        // Now remove the empty cgroup
        deleteDirPath(path) catch {};
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

pub fn makeTempDir() ![]const u8 {
    var rand_buf: [8]u8 = undefined;
    randomBytes(&rand_buf);
    var suffix: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&suffix, "{x:0>16}", .{std.mem.readInt(u64, &rand_buf, .little)}) catch unreachable;
    const path = try std.fmt.allocPrint(allocator, "/tmp/poof-{s}", .{suffix});
    try makeDirPath(path);
    return path;
}

fn chdirTo(path: []const u8) bool {
    const p = posix.toPosixPath(path) catch return false;
    return errnoFromSyscall(linux.chdir(&p)) == .SUCCESS;
}

fn symlinkAt(target: [*:0]const u8, path: []const u8) void {
    const p = posix.toPosixPath(path) catch return;
    _ = linux.symlinkat(target, linux.AT.FDCWD, &p);
}

// FUSE overlay state (for non-root mode)
var fuse_overlay_pid: ?i32 = null;

fn mountFuseOverlay(lower: []const u8, upper: []const u8, work: []const u8, merged: []const u8) !void {
    const opts = try std.fmt.allocPrint(allocator, "lowerdir={s},upperdir={s},workdir={s},squash_to_root", .{ lower, upper, work });
    const opts_z = try allocator.dupeSentinel(u8, opts, 0);
    const merged_z = try allocator.dupeSentinel(u8, merged, 0);

    // Fork and exec fuse-overlayfs in foreground mode (-f)
    // This keeps the FUSE daemon running as a child process
    const pid = linux.fork();
    if (pid == 0) {
        // Child - exec fuse-overlayfs in foreground
        const argv = [_:null]?[*:0]const u8{
            "fuse-overlayfs",
            "-f", // foreground mode - required for chroot to work
            "-o",
            opts_z.ptr,
            merged_z.ptr,
            null,
        };
        _ = linux.execve("/usr/bin/fuse-overlayfs", &argv, @ptrCast(std.c.environ));
        std.process.exit(127); // exec failed
    } else if (pid > 0) {
        // Parent - save PID for cleanup, wait briefly for mount
        fuse_overlay_pid = @intCast(pid);

        // Give fuse-overlayfs time to set up the mount
        sleepNs(0, 100_000_000); // 100ms

        // Check if child exited (indicates failure - it should stay running)
        var status: i32 = 0;
        const wait_result = linux.waitpid(@intCast(pid), &status, linux.W.NOHANG);
        if (wait_result > 0) {
            // Child exited - something went wrong
            fuse_overlay_pid = null;
            const us: u32 = @bitCast(status);
            if (linux.W.IFEXITED(us) and linux.W.EXITSTATUS(us) == 127) {
                return error.FuseOverlayfsNotFound;
            }
            return error.FuseOverlayfsFailed;
        }

        // Verify mount succeeded by checking if merged dir has content
        var dir = DirStream.open(merged) orelse return error.MountVerifyFailed;
        defer dir.close();

        if (dir.next() == null) {
            // Directory is empty - mount didn't work
            return error.MountVerifyFailed;
        }
    } else {
        return error.ForkFailed;
    }
}

// Set up minimal /dev with only safe devices (no disk access!)
fn setupMinimalDev(merged_dir: []const u8) !void {
    const dev_path = try std.fmt.allocPrint(allocator, "{s}/dev", .{merged_dir});

    // Mount tmpfs on /dev
    const dev_z = try allocator.dupeSentinel(u8, dev_path, 0);
    const mount_result = mount("tmpfs", dev_z.ptr, "tmpfs", linux.MS.NOSUID | linux.MS.NOEXEC, "mode=755,size=64k");
    if (mount_result == .err) {
        return error.MountFailed;
    }

    // Create necessary subdirectories
    const pts_path = try std.fmt.allocPrint(allocator, "{s}/pts", .{dev_path});
    makeDirPath(pts_path) catch {};

    const shm_path = try std.fmt.allocPrint(allocator, "{s}/shm", .{dev_path});
    makeDirPath(shm_path) catch {};

    // Bind-mount only safe devices from host
    const safe_devices = [_][]const u8{ "null", "zero", "full", "random", "urandom", "tty" };
    for (safe_devices) |dev| {
        const src = try std.fmt.allocPrint(allocator, "/dev/{s}", .{dev});
        const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dev_path, dev });
        const src_z = try allocator.dupeSentinel(u8, src, 0);
        const dst_z = try allocator.dupeSentinel(u8, dst, 0);

        // Create empty file as mount target
        createFilePath(dst) catch continue;

        // Bind mount the device
        _ = mount(src_z.ptr, dst_z.ptr, "none", linux.MS.BIND, null);
    }

    // Mount devpts for pseudo-terminals
    const pts_z = try allocator.dupeSentinel(u8, pts_path, 0);
    _ = mount("devpts", pts_z.ptr, "devpts", linux.MS.NOSUID | linux.MS.NOEXEC, "newinstance,ptmxmode=0666");

    // Create ptmx symlink (use cwd-relative symlink creation)
    const ptmx_path = try std.fmt.allocPrint(allocator, "{s}/ptmx", .{dev_path});
    symlinkAt("pts/ptmx", ptmx_path);

    log("minimal /dev created (no disk devices)", .{});
}

fn isInOverlayEnvironment() bool {
    var buf: [8192]u8 = undefined;
    const n = readFile("/proc/mounts", &buf) catch return false;
    const data = buf[0..n];

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, ' ');
        _ = parts.next(); // device
        const mountpoint = parts.next() orelse continue;
        const fstype = parts.next() orelse continue;
        if (std.mem.eql(u8, mountpoint, "/") and std.mem.eql(u8, fstype, "overlay")) {
            return true;
        }
    }
    return false;
}

// ============================================================================
// Overlay Setup
// ============================================================================

pub fn setupOverlay(config: Config, use_kernel_overlay: bool) Maybe(void) {
    const in_overlay = isInOverlayEnvironment();
    if (in_overlay) {
        log("detected overlay environment (Docker/container)", .{});
    }

    var upper_dir: []const u8 = undefined;
    var work_dir: []const u8 = undefined;
    var merged_dir: []const u8 = undefined;
    var temp_base: []const u8 = undefined;

    // run mode with user-specified upper dir won't work in overlay environment
    if (in_overlay and config.mode == .run) {
        err("'run' mode not supported in overlay environment (Docker/container)", .{});
        err("use 'exec' mode instead - changes can't persist to overlay filesystem", .{});
        return .{ .err = .INVAL };
    }

    if (config.mode == .exec) {
        // Use temp dir created by parent before fork (so parent knows path for cleanup)
        temp_base = cleanup_temp_base orelse {
            err("temp dir not set up", .{});
            return .{ .err = .NOENT };
        };

        // Always mount tmpfs for exec mode - content vanishes with namespace
        const temp_base_z = allocator.dupeSentinel(u8, temp_base, 0) catch return .{ .err = .NOMEM };
        switch (mount("tmpfs", temp_base_z.ptr, "tmpfs", 0, null)) {
            .err => |e| {
                err("tmpfs mount failed: {}", .{e});
                return .{ .err = e };
            },
            .ok => {},
        }
        log("tmpfs mounted for ephemeral storage", .{});

        upper_dir = std.fmt.allocPrint(allocator, "{s}/upper", .{temp_base}) catch return .{ .err = .NOMEM };
        work_dir = std.fmt.allocPrint(allocator, "{s}/work", .{temp_base}) catch return .{ .err = .NOMEM };
        merged_dir = std.fmt.allocPrint(allocator, "{s}/merged", .{temp_base}) catch return .{ .err = .NOMEM };
    } else {
        // Run mode: upper is user-specified, work/merged must be on same filesystem
        upper_dir = config.upper_dir.?;
        work_dir = std.fmt.allocPrint(allocator, "{s}.work", .{upper_dir}) catch return .{ .err = .NOMEM };
        merged_dir = std.fmt.allocPrint(allocator, "{s}.merged", .{upper_dir}) catch return .{ .err = .NOMEM };
        // cleanup_work_dir and cleanup_merged_dir are set by parent before fork
    }

    // Create directories
    inline for (.{ upper_dir, work_dir, merged_dir }) |dir| {
        makeDirPath(dir) catch |e| {
            if (e != error.PathAlreadyExists) {
                err("mkdir {s}: {}", .{ dir, e });
                return .{ .err = .ACCES };
            }
        };
    }

    log("upper={s}", .{upper_dir});
    log("work={s}", .{work_dir});
    log("merged={s}", .{merged_dir});

    // Make mount tree private
    switch (mount("none", "/", "none", linux.MS.PRIVATE | linux.MS.REC, null)) {
        .err => |e| return .{ .err = e },
        .ok => {},
    }

    // Mount overlay
    const merged_z = allocator.dupeSentinel(u8, merged_dir, 0) catch return .{ .err = .NOMEM };

    if (use_kernel_overlay) {
        // Use kernel overlayfs (requires CAP_SYS_ADMIN)
        const opts_str = std.fmt.allocPrint(allocator, "lowerdir=/,upperdir={s},workdir={s}", .{ upper_dir, work_dir }) catch return .{ .err = .NOMEM };
        const opts = allocator.dupeSentinel(u8, opts_str, 0) catch return .{ .err = .NOMEM };

        switch (mount("overlay", merged_z.ptr, "overlay", 0, opts.ptr)) {
            .err => |e| {
                if (in_overlay and e == .INVAL) {
                    err("overlay stacking limit reached (kernel max: 2 levels)", .{});
                } else if (e == .PERM) {
                    err("overlay mount permission denied", .{});
                    err("try: run as root, or install fuse-overlayfs for unprivileged use", .{});
                }
                return .{ .err = e };
            },
            .ok => {},
        }
        log("overlay mounted (kernel)", .{});
    } else {
        // Use fuse-overlayfs for non-root (with squash_to_root)
        mountFuseOverlay("/", upper_dir, work_dir, merged_dir) catch |e| {
            switch (e) {
                error.FuseOverlayfsNotFound => {
                    err("fuse-overlayfs not found", .{});
                    err("install it: apt install fuse-overlayfs  (or)  pacman -S fuse-overlayfs", .{});
                },
                error.FuseOverlayfsFailed => {
                    err("fuse-overlayfs failed to start", .{});
                    err("make sure /dev/fuse is available (docker run --device /dev/fuse ...)", .{});
                },
                error.MountVerifyFailed => {
                    err("fuse-overlayfs mount failed (empty merged directory)", .{});
                    err("check permissions and /dev/fuse availability", .{});
                },
                else => {
                    err("fuse-overlayfs failed: {}", .{e});
                },
            }
            return .{ .err = .NOENT };
        };
        log("overlay mounted (fuse-overlayfs)", .{});
    }
    vstep("Overlay filesystem ready", .{});

    if (use_kernel_overlay) {
        // Kernel overlay mode: use pivot_root for strong isolation
        // Set up minimal /dev BEFORE pivot_root (device nodes don't work through overlay)
        setupMinimalDev(merged_dir) catch |e| {
            log("failed to set up minimal /dev: {}", .{e});
            // Continue anyway - some things may still work
        };

        const oldroot_str = std.fmt.allocPrint(allocator, "{s}/.oldroot", .{merged_dir}) catch return .{ .err = .NOMEM };
        const oldroot = allocator.dupeSentinel(u8, oldroot_str, 0) catch return .{ .err = .NOMEM };
        makeDirPath(oldroot) catch |e| {
            if (e != error.PathAlreadyExists) return .{ .err = .ACCES };
        };

        switch (pivotRoot(merged_z.ptr, oldroot.ptr)) {
            .err => |e| return .{ .err = e },
            .ok => {},
        }

        if (!chdirTo(config.cwd)) {
            _ = chdirTo("/");
        }

        // Detach old root
        switch (umount2("/.oldroot", linux.MNT.DETACH)) {
            .err => |e| return .{ .err = e },
            .ok => {},
        }
        deleteDirPath("/.oldroot") catch {};

        // Mount fresh /proc for the new PID namespace
        _ = umount2("/proc", linux.MNT.DETACH);
        switch (mount("proc", "/proc", "proc", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, null)) {
            .err => |e| {
                log("failed to mount /proc: {}", .{e});
            },
            .ok => {},
        }

        // Mount fresh /tmp (ensures writable regardless of host permissions)
        _ = umount2("/tmp", linux.MNT.DETACH);
        switch (mount("tmpfs", "/tmp", "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, null)) {
            .err => |e| {
                log("failed to mount /tmp: {}", .{e});
            },
            .ok => {},
        }
    } else {
        // Non-root mode with fuse-overlayfs: use chroot (pivot_root doesn't work with FUSE)
        // Set up minimal /dev (don't bind-mount host /dev - that exposes disk devices!)
        setupMinimalDev(merged_dir) catch |e| {
            log("failed to set up minimal /dev: {}", .{e});
            // Continue anyway - some things may still work
        };

        // Chroot into the merged directory
        const chroot_result = linux.chroot(merged_z.ptr);
        const chroot_err = errnoFromSyscall(chroot_result);
        if (chroot_err != .SUCCESS) {
            err("chroot failed: {}", .{chroot_err});
            return .{ .err = chroot_err };
        }
        if (!chdirTo(config.cwd)) {
            _ = chdirTo("/");
        }
        log("chroot active", .{});

        // Mount fresh /proc for PID namespace (not bind-mount - that would leak host processes)
        switch (mount("proc", "/proc", "proc", linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC, null)) {
            .err => |e| {
                log("failed to mount /proc: {}", .{e});
            },
            .ok => {},
        }

        // Mount fresh /tmp inside chroot
        switch (mount("tmpfs", "/tmp", "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, null)) {
            .err => |e| {
                log("failed to mount /tmp: {}", .{e});
            },
            .ok => {},
        }

        // Create symlinks for standard file descriptors (now that /proc is mounted)
        symlinkAt("/proc/self/fd", "/dev/fd");
        symlinkAt("/proc/self/fd/0", "/dev/stdin");
        symlinkAt("/proc/self/fd/1", "/dev/stdout");
        symlinkAt("/proc/self/fd/2", "/dev/stderr");
    }

    if (output.isVerbose()) {
        success("Environment ready — all changes are isolated", .{});
    }
    return .{ .ok = {} };
}

// ============================================================================
// Child Process Entry Point
// ============================================================================

pub fn childMain(config: Config, orig_uid: u32, orig_gid: u32) noreturn {
    // Set up death signal - if parent dies, we get SIGKILL
    _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @as(usize, @backingInt(linux.SIG.KILL)), 0, 0, 0);

    const is_root = orig_uid == 0;

    // Unshare namespaces: mount, PID, UTS, IPC
    // User namespace only if not root (or if root but lacking CAP_SYS_ADMIN)
    var flags: u32 = linux.CLONE.NEWNS | linux.CLONE.NEWPID | linux.CLONE.NEWUTS | linux.CLONE.NEWIPC;
    var using_user_ns = !is_root;

    if (!is_root) flags |= linux.CLONE.NEWUSER;

    var result = linux.unshare(flags);
    var e = errnoFromSyscall(result);

    // If root but unshare failed (e.g., in Docker without CAP_SYS_ADMIN),
    // retry with user namespace
    if (e == .PERM and is_root) {
        log("no CAP_SYS_ADMIN, falling back to user namespace", .{});
        flags |= linux.CLONE.NEWUSER;
        using_user_ns = true;
        result = linux.unshare(flags);
        e = errnoFromSyscall(result);
    }

    if (e != .SUCCESS) {
        err("unshare failed: {}", .{e});
        if (e == .PERM) {
            err("namespace creation denied - in Docker, use: --security-opt seccomp=unconfined", .{});
        }
        std.process.exit(1);
    }

    // Set up uid/gid mappings for user namespace
    if (using_user_ns) {
        setupUidGidMappings(orig_uid, orig_gid) catch |ue| {
            err("uid/gid mapping failed: {}", .{ue});
            std.process.exit(1);
        };
    }

    // Fork again to enter the new PID namespace (we become PID 1)
    const pid = linux.fork();
    if (pid != 0) {
        // Parent waits for child and exits with its status
        if (pid > 0) {
            var status: i32 = 0;
            _ = linux.waitpid(@intCast(pid), &status, 0);
            const us: u32 = @bitCast(status);
            if ((us & 0x7f) == 0) {
                std.process.exit(@truncate((us >> 8) & 0xff));
            }
            std.process.exit(1);
        } else {
            err("fork failed", .{});
            std.process.exit(1);
        }
    }

    // Now we're PID 1 in the new namespace
    log("entered namespaces (PID={})", .{linux.getpid()});
    vstep("Namespace isolation active", .{});

    // Set up overlay filesystem
    // Use kernel overlayfs only if we have real root (not user namespace)
    const use_kernel_overlay = !using_user_ns;
    switch (setupOverlay(config, use_kernel_overlay)) {
        .err => |oe| {
            err("overlay setup failed: {}", .{oe});
            std.process.exit(1);
        },
        .ok => {},
    }

    // Set IS_SANDBOX=1 environment variable
    _ = setenv("IS_SANDBOX", "1", 1);

    // Execute command
    const argv = allocator.allocSentinel(?[*:0]const u8, config.command.len, null) catch {
        err("out of memory", .{});
        std.process.exit(1);
    };
    for (config.command, 0..) |arg, i| {
        argv[i] = (allocator.dupeSentinel(u8, arg, 0) catch {
            err("out of memory", .{});
            std.process.exit(1);
        }).ptr;
    }

    // execvp resolves argv[0] via PATH and inherits the current environ
    // (which already has IS_SANDBOX=1 set above).
    _ = execvp(argv[0].?, argv.ptr);
    err("exec failed: {s}: {}", .{ config.command[0], c.errno(-1) });
    std.process.exit(127);
}
