const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version from environment or default
    const version = b.option([]const u8, "version", "Version string") orelse "dev";
    // Zig caches the configure step, so a command run here is replayed until
    // build.zig itself changes: the automatic lookup can lag behind HEAD. Release
    // and CI builds pass -Dgit-commit explicitly, which is authoritative; when
    // the value came from the lookup, poof --version says so instead of lying.
    const git_commit_opt = b.option([]const u8, "git-commit", "Git commit hash (authoritative)");
    const git_commit_explicit = git_commit_opt != null;
    const git_commit = git_commit_opt orelse blk: {
        const result = b.runFallible(&.{ "git", "rev-parse", "--short", "HEAD" }, .{
            .stderr_behavior = .ignore,
        });
        break :blk switch (result) {
            .success => |stdout| std.mem.trim(u8, stdout, "\n\r "),
            else => "",
        };
    };

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "git_commit", git_commit);
    options.addOption(bool, "git_commit_explicit", git_commit_explicit);

    const exe = b.addExecutable(.{
        .name = "poof",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run poof");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // Forward `zig build run -- <args>` to the program.
    run_cmd.addPassthruArgs();
}
