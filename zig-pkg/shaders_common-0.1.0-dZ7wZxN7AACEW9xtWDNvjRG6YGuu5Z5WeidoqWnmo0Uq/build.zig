const std = @import("std");

pub fn build(b: *std.Build) void {
    // This is a header-only library, no compilation needed
    // The paths are exposed via b.path() for consumers
    _ = b;
}
