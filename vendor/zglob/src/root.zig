//! zglob - glob pattern matching, ported from Rust
//!
//! Vendored subset: only the pattern matcher is kept. poof walks the stash
//! itself (src/sandbox.zig), so upstream's file finding (glob.zig) and
//! filesystem layer (fs.zig) are dropped rather than ported. See VENDOR.md.

pub const match = @import("match.zig");

pub const globMatch = match.globMatch;
pub const globMatchWithCaptures = match.globMatchWithCaptures;
pub const Capture = match.Capture;
pub const MatchGlob = match.MatchGlob;
