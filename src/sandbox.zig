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

// linux.fork() returns a raw usize: on failure the kernel's -errno is bit-cast into
// it, so the value must be read as signed before it is used as a pid. Comparing the
// usize directly makes every failure look like a valid (huge) child pid.
pub const ForkResult = struct { pid: i32, errno: Errno };

pub fn forkChild() ForkResult {
    const r = linux.fork();
    const e = errnoFromSyscall(r);
    if (e != .SUCCESS) return .{ .pid = -1, .errno = e };
    return .{ .pid = @intCast(@as(isize, @bitCast(r))), .errno = .SUCCESS };
}

// What happens to a session's upper dir once the session ends. This is the only
// thing that ever distinguished poof's old exec/run/enter "modes": the sandbox is
// identical in all three, and what differs is whether the changes outlive it.
pub const Keep = enum {
    auto, // stash in a /tmp/poof-<hex> dir poof picks
    dir, // stash in a --keep=<dir> the caller chose
    none, // --no-keep: the upper lives on a tmpfs that dies with the namespace
};

// When poof offers to replay a session's changes onto the host.
pub const ApplyAtExit = enum {
    never, // leave the stash for `poof apply`
    ask, // show the change list, then prompt (a terminal is needed)
    always, // apply without asking (--yes)
};

pub const Config = struct {
    keep: Keep = .auto,
    apply_at_exit: ApplyAtExit = .never,
    command: []const []const u8,
    upper_dir: ?[]const u8 = null,
    verbose: bool = false,
    cwd: []const u8 = "/",
    // Resource limits (cgroups v2)
    memory_limit: ?u64 = null, // bytes
    pids_limit: ?u32 = null, // max processes
    // Timeout
    timeout: ?u32 = null, // seconds
    // The directory an exit-time apply writes into. Null means no exit-time apply:
    // the stash is left for `poof apply <stash>` instead.
    apply_target: ?[]const u8 = null,
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

/// mkdir -p: create `path` and any missing parents.
pub fn makeDirs(path: []const u8) FsError!void {
    if (path.len == 0) return;
    if (path.len > 4000) return error.NameTooLong;

    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    const n = path.len;

    var i: usize = 1;
    while (i <= n) : (i += 1) {
        if (i < n and buf[i] != '/') continue;
        const saved = buf[i];
        buf[i] = 0;
        const seg: [*:0]const u8 = buf[0..i :0];
        const e = errnoFromSyscall(linux.mkdir(seg, 0o755));
        switch (e) {
            .SUCCESS, .EXIST => {},
            else => return fsError(e),
        }
        buf[i] = saved;
    }
}

/// True when `path` exists and is a directory (opening with O_DIRECTORY is the
/// portable way to ask, no stat layout differences per architecture).
pub fn isDirectory(path: []const u8) bool {
    const p = posix.toPosixPath(path) catch return false;
    const fd = linux.open(&p, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (errnoFromSyscall(fd) != .SUCCESS) return false;
    _ = linux.close(@intCast(fd));
    return true;
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

    const forked = forkChild();
    if (forked.pid == 0) {
        _ = execvp(argvz[0].?, argvz.ptr);
        c._exit(127);
    } else if (forked.pid > 0) {
        var status: i32 = 0;
        const waited = linux.waitpid(forked.pid, &status, 0);
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
pub var cleanup_temp_base: ?[]const u8 = null; // --no-keep and kept-for-apply sessions: temp dir to delete
pub var cleanup_work_dir: ?[]const u8 = null; // kept changes: the .work dir beside the stash
pub var cleanup_merged_base: ?[]const u8 = null; // kept changes: temp dir hosting the merged mount point

pub fn cleanupOverlayDirs() void {
    // Delete temp base directory (--no-keep, and a session whose changes were applied)
    if (cleanup_temp_base) |path| {
        deleteTree(path);
    }
    // Run mode: delete the .work directory we created next to the user's upper dir
    if (cleanup_work_dir) |path| {
        deleteTree(path);
    }
    // Run/enter mode: the empty dir that hosted the merged mount point. Its contents
    // lived on a tmpfs that died together with the child's mount namespace.
    if (cleanup_merged_base) |path| {
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

/// Read our own cgroup path from /proc/self/cgroup, e.g. "/user.slice/.../app.slice/foo.scope".
fn getMyCgroupRel() ?[]const u8 {
    var buf: [1024]u8 = undefined;
    const n = readFile("/proc/self/cgroup", &buf) catch return null;
    const data = buf[0..n];
    const idx = std.mem.indexOf(u8, data, "::") orelse return null;
    const rest = data[idx + 2 ..];
    const end = std.mem.indexOf(u8, rest, "\n") orelse rest.len;
    var rel = rest[0..end];
    if (rel.len == 0 or rel[0] != '/') return null;
    if (std.mem.eql(u8, rel, "/")) rel = ""; // the root cgroup
    return std.fmt.allocPrint(allocator, "{s}", .{rel}) catch null;
}

/// Controllers enabled for children in `base`. Returns the names, space separated
/// as they appear in cgroup.subtree_control.
fn readControllers(path: []const u8, buf: []u8) ?[]const u8 {
    const n = readFile(path, buf) catch return null;
    const data = std.mem.trim(u8, buf[0..n], " \t\n\r");
    return allocator.dupe(u8, data) catch null;
}

/// Controllers we need enabled in the leaf cgroup.
const WantedControllers = struct {
    names: [8][]const u8 = undefined,
    len: usize = 0,

    fn add(self: *WantedControllers, name: []const u8) void {
        for (self.names[0..self.len]) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        if (self.len == self.names.len) return;
        self.names[self.len] = name;
        self.len += 1;
    }
};

/// Create poof's cgroup under the closest ancestor of our own cgroup that allows it.
///
/// Three kernel rules make this fiddly for an unprivileged poof:
///   * a cgroup that has processes attached cannot enable controllers for its
///     children, so inside a systemd scope the leaf has to go one level up;
///   * the leaf must have the *same* controllers enabled as the cgroup the process
///     is moved out of, otherwise writing cgroup.procs fails with EOPNOTSUPP;
///   * only the root cgroup is exempt from the first rule, which is why the old
///     top-level placement only ever worked for root and inside containers.
///
/// So each candidate is attempted end to end (enable controllers, mkdir, set
/// limits, attach) and we move one level up whenever any step is refused.
fn setupSandboxCgroup(config: Config, suffix: []const u8) ?[]const u8 {
    var ctrl_buf: [512]u8 = undefined;

    // Controllers we must enable in the leaf: the ones the caller asked for, plus
    // every controller already active on our own cgroup (migration set match).
    var wanted = WantedControllers{};
    if (config.memory_limit != null) wanted.add("memory");
    if (config.pids_limit != null) wanted.add("pids");
    if (getMyCgroupRel()) |my_rel| {
        var own_buf: [512]u8 = undefined;
        const own_path = std.fmt.bufPrint(&own_buf, "/sys/fs/cgroup{s}/cgroup.controllers", .{my_rel}) catch null;
        if (own_path) |p| {
            if (readControllers(p, &ctrl_buf)) |list| {
                var it = std.mem.tokenizeScalar(u8, list, ' ');
                while (it.next()) |name| wanted.add(name);
            }
        }
    }

    var rel: []const u8 = getMyCgroupRel() orelse "";

    while (true) {
        var base_buf: [1024]u8 = undefined;
        const base = std.fmt.bufPrint(&base_buf, "/sys/fs/cgroup{s}", .{rel}) catch return null;

        var ok = true;
        var sub_buf: [1100]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/cgroup.subtree_control", .{base}) catch return null;

        // The root cgroup already has its controllers wired up and is exempt from
        // the no-internal-processes rule, so don't touch it unless we have to.
        if (rel.len > 0) {
            for (wanted.names[0..wanted.len]) |name| {
                var w_buf: [64]u8 = undefined;
                const plus = std.fmt.bufPrint(&w_buf, "+{s}", .{name}) catch {
                    ok = false;
                    break;
                };
                writeFile(sub_path, plus) catch |e| {
                    vstep("cannot enable {s} controller in {s}: {}", .{ name, base, e });
                    ok = false;
                    break;
                };
            }
        }

        if (ok) {
            var leaf_buf: [1100]u8 = undefined;
            const leaf = std.fmt.bufPrint(&leaf_buf, "{s}/poof-{s}", .{ base, suffix }) catch return null;
            makeDirPath(leaf) catch |e| {
                vstep("cannot create cgroup under {s}: {}", .{ base, e });
                ok = false;
            };

            if (ok) {
                ok = writeCgroupLimits(leaf, config);
                // The sandbox attaches itself to the leaf (attachToCgroup, called in
                // the forked child); poof's own process deliberately stays outside so
                // an OOM kill cannot take down the process that cleans up afterwards.
                if (ok) return allocator.dupe(u8, leaf) catch return null;

                // Roll back the empty leaf before trying the next ancestor.
                deleteDirPath(leaf) catch {};
            }
        }

        if (rel.len == 0) return null; // tried the root cgroup already
        const cut = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return null;
        rel = rel[0..cut]; // one level up
    }
}

fn writeCgroupLimits(leaf: []const u8, config: Config) bool {
    var buf: [64]u8 = undefined;

    // Set memory limit
    if (config.memory_limit) |mem| {
        const path = std.fmt.allocPrint(allocator, "{s}/memory.max", .{leaf}) catch return false;
        const content = std.fmt.bufPrint(&buf, "{d}", .{mem}) catch return false;
        writeFile(path, content) catch |e| {
            log("failed to set memory limit: {}", .{e});
            return false;
        };
        log("cgroup memory.max={d}", .{mem});

        // memory.max alone is not a cap: with swap available the kernel just pages
        // the excess out instead of enforcing the limit, so pin swap to zero.
        const swap_path = std.fmt.allocPrint(allocator, "{s}/memory.swap.max", .{leaf}) catch null;
        if (swap_path) |sp| {
            writeFile(sp, "0") catch |e| {
                vstep("cannot disable swap for the sandbox: {}", .{e});
            };
        }

        // Kill the whole sandbox on OOM rather than letting it limp on.
        const oom_path = std.fmt.allocPrint(allocator, "{s}/memory.oom.group", .{leaf}) catch null;
        if (oom_path) |op| {
            writeFile(op, "1") catch |e| {
                vstep("cannot set memory.oom.group: {}", .{e});
            };
        }
    }

    // Set pids limit
    if (config.pids_limit) |pids| {
        const path = std.fmt.allocPrint(allocator, "{s}/pids.max", .{leaf}) catch return false;
        const content = std.fmt.bufPrint(&buf, "{d}", .{pids}) catch return false;
        writeFile(path, content) catch |e| {
            log("failed to set pids limit: {}", .{e});
            return false;
        };
        log("cgroup pids.max={d}", .{pids});
    }

    return true;
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

    cgroup_path = setupSandboxCgroup(config, &suffix) orelse return error.CgroupsNotAvailable;

    log("cgroup created: {s}", .{cgroup_path.?});
}

/// Move the calling process (the sandbox) into the limits cgroup that setupCgroup
/// prepared. Called from the forked child, before it does anything else, so the
/// whole sandbox tree is covered while poof's parent stays outside the cgroup.
pub fn attachToCgroup() !void {
    const path = cgroup_path orelse return;
    var procs_buf: [1200]u8 = undefined;
    var pid_buf: [32]u8 = undefined;
    const procs_path = std.fmt.bufPrint(&procs_buf, "{s}/cgroup.procs", .{path}) catch return error.Unexpected;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{linux.getpid()}) catch return error.Unexpected;
    writeFile(procs_path, pid_str) catch |e| {
        err("cannot move sandbox into cgroup {s}: {}", .{ path, e });
        return e;
    };
    log("sandbox attached to cgroup {s}", .{path});
}

pub fn cleanupCgroup() void {
    if (cgroup_path) |path| {
        // Move ourselves back to original cgroup first
        if (original_cgroup) |orig| {
            var buf: [32]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&buf, "{d}", .{linux.getpid()}) catch return;
            writeFile(orig, pid_str) catch {};
        }

        // Now remove the empty cgroup. The last process out (typically the
        // fuse-overlayfs daemon) may still be in the middle of leaving, which makes
        // rmdir fail with ENOTEMPTY, so retry briefly instead of leaking the cgroup.
        var attempt: usize = 0;
        while (attempt < 20) : (attempt += 1) {
            deleteDirPath(path) catch |e| switch (e) {
                error.DirNotEmpty, error.Unexpected, error.PermissionDenied => {
                    sleepNs(0, 50_000_000);
                    continue;
                },
                else => break,
            };
            break;
        }
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
    const forked = forkChild();
    if (forked.pid == 0) {
        // Child - exec fuse-overlayfs in foreground
        // PDEATHSIG survives execve, so the daemon goes away together with the
        // sandboxed process instead of lingering with the FUSE connection and our
        // inherited stdio pipes held open.
        _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @as(usize, @backingInt(linux.SIG.KILL)), 0, 0, 0);
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
    } else if (forked.pid > 0) {
        // Parent - save PID for cleanup, wait briefly for mount
        fuse_overlay_pid = forked.pid;

        // Give fuse-overlayfs time to set up the mount
        sleepNs(0, 100_000_000); // 100ms

        // Check if child exited (indicates failure - it should stay running)
        var status: i32 = 0;
        const wait_result = linux.waitpid(forked.pid, &status, linux.W.NOHANG);
        if (errnoFromSyscall(wait_result) == .SUCCESS and wait_result > 0) {
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

// /proc/mounts escapes whitespace in mount points as \040, \011 and \012.
fn unescapeMount(raw: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (n >= buf.len) return null;
        if (raw[i] == '\\' and i + 3 < raw.len) {
            const octal = std.fmt.parseInt(u8, raw[i + 1 .. i + 4], 8) catch { //
                buf[n] = raw[i];
                n += 1;
                i += 1;
                continue;
            };
            buf[n] = octal;
            n += 1;
            i += 4;
            continue;
        }
        buf[n] = raw[i];
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

pub const Mount = struct {
    point: []const u8,
    fstype: []const u8,
};

/// The mount a path sits on, from /proc/mounts: the longest mount point that
/// prefixes it. The path does not have to exist. point_buf/fstype_buf receive the
/// winning entry (mount points are unescaped from \040-style octal), so the result
/// outlives the mount table buffer.
pub fn mountOf(path: []const u8, point_buf: []u8, fstype_buf: []u8) ?Mount {
    var buf: [8192]u8 = undefined;
    const n = readFile("/proc/mounts", &buf) catch return null;
    const data = buf[0..n];

    var name_buf: [4096]u8 = undefined;
    var found = false;
    var point_len: usize = 0;
    var fstype_len: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, ' ');
        _ = parts.next(); // device
        const raw = parts.next() orelse continue; // mount point
        const fstype = parts.next() orelse continue;
        const point = unescapeMount(raw, &name_buf) orelse continue;
        if (point.len <= point_len) continue;
        // The path is on this mount when it is the mount point itself, or sits below
        // it. A one-character point is "/", which covers every absolute path.
        const covers = std.mem.eql(u8, path, point) or
            (std.mem.startsWith(u8, path, point) and (point.len == 1 or path[point.len] == '/'));
        // Copied out on the spot: name_buf is reused for the next line, so a slice
        // of it would be overwritten before the loop ends.
        if (covers and point.len <= point_buf.len and fstype.len <= fstype_buf.len) {
            @memcpy(point_buf[0..point.len], point);
            @memcpy(fstype_buf[0..fstype.len], fstype);
            point_len = point.len;
            fstype_len = fstype.len;
            found = true;
        }
    }

    if (!found) return null;
    return Mount{ .point = point_buf[0..point_len], .fstype = fstype_buf[0..fstype_len] };
}

/// Filesystem type of the mount a path sits on. Allocated from the global arena.
pub fn fsTypeOf(path: []const u8) ?[]const u8 {
    var point_buf: [4096]u8 = undefined;
    var fstype_buf: [64]u8 = undefined;
    const m = mountOf(path, &point_buf, &fstype_buf) orelse return null;
    return std.fmt.allocPrint(allocator, "{s}", .{m.fstype}) catch null;
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

    if (config.keep == .none) {
        // Use temp dir created by parent before fork (so parent knows path for cleanup)
        temp_base = cleanup_temp_base orelse {
            err("temp dir not set up", .{});
            return .{ .err = .NOENT };
        };

        // Always mount tmpfs for --no-keep - content vanishes with the namespace
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
        // Keeping changes: upper is the user's --keep dir or poof's own stash dir, and
        // work has to sit on the same filesystem as upper (kernel overlay requirement).
        // The merged mount
        // point must NOT be reachable from inside the sandbox: when anything walks the
        // directory holding it, fuse-overlayfs ends up opening its own mount point and
        // deadlocks. So merged lives under a private tmpfs in /tmp - the fresh /tmp we
        // mount after chroot/pivot_root hides it, same layout that makes --no-keep safe.
        upper_dir = config.upper_dir.?;
        work_dir = std.fmt.allocPrint(allocator, "{s}.work", .{upper_dir}) catch return .{ .err = .NOMEM };

        temp_base = cleanup_merged_base orelse {
            err("merged temp base not set up", .{});
            return .{ .err = .NOENT };
        };
        const merged_base_z = allocator.dupeSentinel(u8, temp_base, 0) catch return .{ .err = .NOMEM };
        switch (mount("tmpfs", merged_base_z.ptr, "tmpfs", 0, null)) {
            .err => |e| {
                err("tmpfs mount for merged dir failed: {}", .{e});
                return .{ .err = e };
            },
            .ok => {},
        }
        log("tmpfs mounted for merged mount point", .{});

        merged_dir = std.fmt.allocPrint(allocator, "{s}/merged", .{temp_base}) catch return .{ .err = .NOMEM };
        // cleanup_work_dir and cleanup_merged_base are set by parent before fork
    }

    // Kernel overlayfs refuses an upperdir that is itself on an overlay mount -
    // that is what makes 'run' mode fail inside Docker, where the container root
    // is overlayfs. The constraint belongs to the upper dir's own filesystem, not
    // to the root's: an upper on tmpfs or on a bind-mounted volume works, so only
    // refuse when the upper really is on overlay. fuse-overlayfs (used when there
    // is no real root) still refuses, as before.
    if (config.keep != .none and use_kernel_overlay) {
        if (fsTypeOf(upper_dir)) |fstype| {
            if (std.mem.eql(u8, fstype, "overlay")) {
                err("the stash cannot live on overlayfs: {s} is on an overlay mount", .{upper_dir});
                err("move it with --keep=<dir> onto a tmpfs or a volume (in Docker: --tmpfs /var/tmp)", .{});
                err("or drop the changes entirely: poof --no-keep <program>", .{});
                return .{ .err = .INVAL };
            }
        }
    }
    if (config.keep != .none and !use_kernel_overlay and in_overlay) {
        err("keeping changes is not supported in an overlay environment (Docker/container)", .{});
        err("the stash cannot persist on an overlay filesystem: --keep=<dir> on a tmpfs or a volume, or --no-keep to drop the changes", .{});
        return .{ .err = .INVAL };
    }

    // Create the upper directory (and any missing parents), then check it really
    // is a directory: otherwise fuse-overlayfs fails with an unrelated error.
    makeDirs(upper_dir) catch |e| {
        err("mkdir {s}: {}", .{ upper_dir, e });
        return .{ .err = .ACCES };
    };
    if (!isDirectory(upper_dir)) {
        err("upper path is not a directory: {s}", .{upper_dir});
        return .{ .err = .NOTDIR };
    }

    inline for (.{ work_dir, merged_dir }) |dir| {
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

    // fuse-overlayfs refuses to read a directory that contains its own upperdir or
    // workdir (readdir fails with EIO), and with lowerdir=/ those always sit inside the
    // tree the sandbox walks - so `ls` in the directory holding --upper would break.
    // Kernel overlayfs hides upper/work from the merged view; emulate that here: hand
    // fuse a bind of upper's *parent* (upper and work must stay on one mount, or
    // copy-up's rename gets EXDEV) and shadow the originals with an empty bind.
    var fuse_upper = upper_dir;
    var fuse_work = work_dir;
    if (!use_kernel_overlay and config.keep != .none) {
        const store_dir = std.fmt.allocPrint(allocator, "{s}/store", .{temp_base}) catch return .{ .err = .NOMEM };
        const empty_dir = std.fmt.allocPrint(allocator, "{s}/empty", .{temp_base}) catch return .{ .err = .NOMEM };
        makeDirPath(store_dir) catch |e| {
            if (e != error.PathAlreadyExists) return .{ .err = .ACCES };
        };
        makeDirPath(empty_dir) catch |e| {
            if (e != error.PathAlreadyExists) return .{ .err = .ACCES };
        };

        const upper_parent = std.fs.path.dirname(upper_dir) orelse "/";
        const work_parent = std.fs.path.dirname(work_dir) orelse "/";
        if (std.mem.eql(u8, upper_parent, work_parent)) {
            const store_z = allocator.dupeSentinel(u8, store_dir, 0) catch return .{ .err = .NOMEM };
            const empty_z = allocator.dupeSentinel(u8, empty_dir, 0) catch return .{ .err = .NOMEM };
            const upper_z = allocator.dupeSentinel(u8, upper_dir, 0) catch return .{ .err = .NOMEM };
            const work_z = allocator.dupeSentinel(u8, work_dir, 0) catch return .{ .err = .NOMEM };
            const parent_z = allocator.dupeSentinel(u8, upper_parent, 0) catch return .{ .err = .NOMEM };

            switch (mount(parent_z.ptr, store_z.ptr, "none", linux.MS.BIND, null)) {
                .ok => {
                    _ = mount(empty_z.ptr, upper_z.ptr, "none", linux.MS.BIND, null);
                    _ = mount(empty_z.ptr, work_z.ptr, "none", linux.MS.BIND, null);
                    fuse_upper = std.fmt.allocPrint(allocator, "{s}/{s}", .{ store_dir, std.fs.path.basename(upper_dir) }) catch return .{ .err = .NOMEM };
                    fuse_work = std.fmt.allocPrint(allocator, "{s}/{s}", .{ store_dir, std.fs.path.basename(work_dir) }) catch return .{ .err = .NOMEM };
                    log("upper/work hidden from sandbox view (fuse)", .{});
                },
                // A mount root (e.g. --upper=/somewhere) cannot be bind mounted from
                // inside a user namespace; fall back to the original layout.
                .err => |e| log("cannot bind {s}: {} - keeping original layout", .{ upper_parent, e }),
            }
        }
    }

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
        mountFuseOverlay("/", fuse_upper, fuse_work, merged_dir) catch |e| {
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
                error.ForkFailed => {
                    err("cannot start fuse-overlayfs: no process slots left (--pids is too small)", .{});
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

    // Join the resource-limit cgroup before unsharing anything: the cgroup files are
    // owned by the real uid, and everything forked below inherits the membership.
    if (cgroup_path != null) {
        attachToCgroup() catch std.process.exit(1);
    }

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

    // Fork again to enter the new PID namespace (the child becomes PID 1)
    const forked = forkChild();
    if (forked.pid != 0) {
        // Parent waits for child and exits with its status
        if (forked.pid > 0) {
            // Forward interrupts to the namespace instead of dying here: the sandbox
            // tears itself down once the command is gone, which keeps the mount and
            // PID namespaces from being torn out from under a running command.
            forward_to_pid = forked.pid;
            installSignalForwarding();

            var status: i32 = 0;
            while (true) {
                const r = linux.waitpid(forked.pid, &status, 0);
                if (errnoFromSyscall(r) != .SUCCESS) continue; // EINTR from a forwarded signal
                break;
            }
            const us: u32 = @bitCast(status);
            if ((us & 0x7f) == 0) {
                std.process.exit(@truncate((us >> 8) & 0xff));
            }
            std.process.exit(128 + @as(u8, @truncate(us & 0x7f)));
        } else {
            err("fork failed: {}", .{forked.errno});
            if (forked.errno == .AGAIN) {
                err("not enough processes allowed to start the sandbox (--pids is too small)", .{});
            }
            std.process.exit(1);
        }
    }

    // Now we're PID 1 in the new namespace
    // PDEATHSIG is not inherited across fork, so set it again here: it survives execve,
    // which means the sandboxed command dies together with this namespace's parent when
    // poof times out or gets interrupted. Without it the command (and the FUSE daemon it
    // spawned) outlives the sandbox and keeps inherited file descriptors open.
    _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @as(usize, @backingInt(linux.SIG.KILL)), 0, 0, 0);

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

    // Run the command as a child of this namespace's init rather than *as* it. The
    // kernel discards unhandled terminating signals for a pid namespace's PID 1 (only
    // SIGKILL reaches it) and swallows crash signals outright, so a command running as
    // PID 1 cannot be stopped with SIGTERM/SIGINT and a segfault turns into a clean
    // exit 0. This process is the tiny init: it forwards signals to the command and
    // reports its real status (128+signum when killed by a signal).
    forward_to_pid = 0;
    installSignalForwarding();

    // Hold the forwarded signals blocked across the fork and the forward_to_pid
    // assignment below. A TERM landing in that window would reach forwardSignal while
    // forward_to_pid is still 0, be dropped, and leave this process waiting for a
    // command nothing will ever signal - and poof's signal handler waiting on this
    // process forever. Blocked, the signal stays pending until there is something to
    // forward it to.
    var fwd_block = linux.sigemptyset();
    linux.sigaddset(&fwd_block, linux.SIG.INT);
    linux.sigaddset(&fwd_block, linux.SIG.TERM);
    linux.sigaddset(&fwd_block, linux.SIG.HUP);
    linux.sigaddset(&fwd_block, linux.SIG.QUIT);
    _ = linux.sigprocmask(linux.SIG.BLOCK, &fwd_block, null);

    const cmd_pid = forkChild();
    if (cmd_pid.pid == 0) {
        // The mask survives fork and exec, and the command must be interruptible.
        var clear = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &clear, null);

        // execvp resolves argv[0] via PATH and inherits the current environ
        // (which already has IS_SANDBOX=1 set above).
        _ = execvp(argv[0].?, argv.ptr);
        const exec_errno = c.errno(-1);
        switch (exec_errno) {
            .ACCES => {
                err("cannot execute {s}: permission denied", .{config.command[0]});
                std.process.exit(126); // shell convention: found but not executable
            },
            .NOENT => {
                err("command not found: {s}", .{config.command[0]});
                std.process.exit(127);
            },
            else => {
                err("exec failed: {s}: {s}", .{ config.command[0], @tagName(exec_errno) });
                std.process.exit(127);
            },
        }
    }
    if (cmd_pid.pid < 0) {
        err("fork failed: {}", .{cmd_pid.errno});
        if (cmd_pid.errno == .AGAIN) {
            err("not enough processes allowed to run the command (--pids is too small)", .{});
        }
        std.process.exit(1);
    }
    forward_to_pid = cmd_pid.pid;

    // Unblock: anything that arrived during the window is delivered now, and
    // forwardSignal has a command to pass it to.
    var unblock = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &unblock, null);

    var status: i32 = 0;
    while (true) {
        const r = linux.waitpid(cmd_pid.pid, &status, 0);
        if (errnoFromSyscall(r) != .SUCCESS) continue; // EINTR from a forwarded signal
        break;
    }
    const us: u32 = @bitCast(status);
    if (linux.W.IFSIGNALED(us)) {
        std.process.exit(128 + @as(u8, @truncate(us & 0x7f)));
    }
    std.process.exit(@truncate((us >> 8) & 0xff));
}

// Signal forwarding down the sandbox chain: poof's parent -> namespace parent ->
// namespace init -> command. Each hop only knows its own child.
var forward_to_pid: i32 = 0;

fn forwardSignal(sig: linux.SIG) callconv(.c) void {
    if (forward_to_pid > 0) _ = linux.kill(forward_to_pid, sig);
}

fn installSignalForwarding() void {
    var action: linux.Sigaction = .{
        .handler = .{ .handler = forwardSignal },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.INT, &action, null);
    _ = linux.sigaction(linux.SIG.TERM, &action, null);
    _ = linux.sigaction(linux.SIG.HUP, &action, null);
    _ = linux.sigaction(linux.SIG.QUIT, &action, null);
}
