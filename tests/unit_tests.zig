const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");

const AwkOptions = gpu.AwkOptions;

// ============================================================================
// Unit Tests for gawk
// Tests basic functionality with small inputs to verify correctness
// ============================================================================

// ----------------------------------------------------------------------------
// CPU Tests
// ----------------------------------------------------------------------------

test "cpu: simple pattern match" {
    const allocator = std.testing.allocator;
    const text = "hello world\nhello there\ngoodbye world";
    const pattern = "hello";

    var result = try cpu.processAwk(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "cpu: case insensitive match" {
    const allocator = std.testing.allocator;
    const text = "Hello world\nHELLO there\nhello again";
    const pattern = "hello";

    var result = try cpu.processAwk(text, pattern, .{ .case_insensitive = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "cpu: no matches" {
    const allocator = std.testing.allocator;
    const text = "hello world\ntest line";
    const pattern = "xyz";

    var result = try cpu.processAwk(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 0), result.total_matches);
}

test "cpu: empty pattern matches all lines" {
    const allocator = std.testing.allocator;
    const text = "line1\nline2\nline3";
    const pattern = "";

    var result = try cpu.processAwk(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "cpu: field splitting whitespace" {
    const allocator = std.testing.allocator;
    const text = "field1 field2 field3";
    const pattern = "";

    var result = try cpu.processAwk(text, pattern, .{}, allocator);
    defer result.deinit();

    // Should have 3 fields for the one matching line
    try std.testing.expect(result.fields.len >= 3);
}

test "cpu: field splitting custom separator" {
    const allocator = std.testing.allocator;
    const text = "a:b:c";
    const pattern = "";

    var result = try cpu.processAwk(text, pattern, .{ .field_separator = ":" }, allocator);
    defer result.deinit();

    // Should have 3 fields
    try std.testing.expect(result.fields.len >= 3);
}

test "cpu: invert match" {
    const allocator = std.testing.allocator;
    const text = "has pattern\nno match\nanother pattern";
    const pattern = "pattern";

    var result = try cpu.processAwk(text, pattern, .{ .invert_match = true }, allocator);
    defer result.deinit();

    // Only "no match" line should match
    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

// ----------------------------------------------------------------------------
// Metal GPU Tests (macOS only)
// ----------------------------------------------------------------------------

test "metal: shader compilation" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const searcher = gpu.metal.MetalAwk.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    // If we get here, shader compiled successfully
}

test "metal: simple pattern match" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const searcher = gpu.metal.MetalAwk.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    const text = "hello world\nhello there\ngoodbye world";
    const pattern = "hello";

    var result = try searcher.processAwk(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "metal: matches cpu results" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const searcher = gpu.metal.MetalAwk.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    const test_cases = [_]struct {
        text: []const u8,
        pattern: []const u8,
        options: AwkOptions,
    }{
        .{ .text = "line1 the\nline2 the\nline3", .pattern = "the", .options = .{} },
        .{ .text = "Hello HELLO hello", .pattern = "hello", .options = .{ .case_insensitive = true } },
        .{ .text = "abc\nabc\nabc", .pattern = "abc", .options = .{} },
    };

    for (test_cases) |tc| {
        var cpu_result = try cpu.processAwk(tc.text, tc.pattern, tc.options, allocator);
        defer cpu_result.deinit();

        var metal_result = try searcher.processAwk(tc.text, tc.pattern, tc.options, allocator);
        defer metal_result.deinit();

        if (cpu_result.total_matches != metal_result.total_matches) {
            std.debug.print("\nMismatch for pattern '{s}':\n", .{tc.pattern});
            std.debug.print("  CPU: {d}, Metal: {d}\n", .{ cpu_result.total_matches, metal_result.total_matches });
            return error.MatchCountMismatch;
        }
    }
}

// ----------------------------------------------------------------------------
// Vulkan GPU Tests
// ----------------------------------------------------------------------------

test "vulkan: shader compilation" {
    const allocator = std.testing.allocator;

    const searcher = gpu.vulkan.VulkanAwk.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    // If we get here, shader loaded successfully
}

test "vulkan: simple pattern match" {
    const allocator = std.testing.allocator;

    const searcher = gpu.vulkan.VulkanAwk.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    const text = "hello world\nhello there\ngoodbye world";
    const pattern = "hello";

    var result = try searcher.processAwk(text, pattern, .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "vulkan: matches cpu results" {
    const allocator = std.testing.allocator;

    const searcher = gpu.vulkan.VulkanAwk.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer searcher.deinit();

    const test_cases = [_]struct {
        text: []const u8,
        pattern: []const u8,
        options: AwkOptions,
    }{
        .{ .text = "line1 the\nline2 the\nline3", .pattern = "the", .options = .{} },
        .{ .text = "Hello HELLO hello", .pattern = "hello", .options = .{ .case_insensitive = true } },
        .{ .text = "abc\nabc\nabc", .pattern = "abc", .options = .{} },
    };

    for (test_cases) |tc| {
        var cpu_result = try cpu.processAwk(tc.text, tc.pattern, tc.options, allocator);
        defer cpu_result.deinit();

        var vulkan_result = try searcher.processAwk(tc.text, tc.pattern, tc.options, allocator);
        defer vulkan_result.deinit();

        if (cpu_result.total_matches != vulkan_result.total_matches) {
            std.debug.print("\nMismatch for pattern '{s}':\n", .{tc.pattern});
            std.debug.print("  CPU: {d}, Vulkan: {d}\n", .{ cpu_result.total_matches, vulkan_result.total_matches });
            return error.MatchCountMismatch;
        }
    }
}
