// Shadow library - ephemeral overlay filesystem environments
const std = @import("std");

pub const main = @import("main.zig");
pub const diffview = @import("diffview.zig");

// Pull the module's tests into the test binary (`zig build test`).
test {
    std.testing.refAllDecls(diffview);
}
