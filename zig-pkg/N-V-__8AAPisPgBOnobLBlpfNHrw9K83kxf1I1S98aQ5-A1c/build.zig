const std = @import("std");

pub fn build(b: *std.Build) void {
    // Create zigtrait module
    const zigtrait_module = b.addModule("zigtrait", .{
        .root_source_file = b.path("libs/zigtrait/src/zigtrait.zig"),
    });

    // Create zig-metal module
    _ = b.addModule("zig-metal", .{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "zigtrait", .module = zigtrait_module },
        },
    });
}
