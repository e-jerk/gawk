const std = @import("std");
const gpu = @import("gpu");
const cpu_optimized = @import("cpu_optimized");

const AwkOptions = gpu.AwkOptions;
const AwkResult = gpu.AwkResult;
const SubstitutionResult = gpu.SubstitutionResult;

/// GNU gawk backend for AWK processing.
/// Note: GNU gawk's processing is tightly integrated with its interpreter,
/// making it difficult to extract just the pattern matching and field splitting.
/// This backend delegates to the optimized implementation which provides
/// equivalent POSIX AWK semantics.
pub fn processAwk(
    text: []const u8,
    pattern: []const u8,
    options: AwkOptions,
    allocator: std.mem.Allocator,
) !AwkResult {
    // Delegate to optimized backend - same AWK semantics
    return cpu_optimized.processAwk(text, pattern, options, allocator);
}

/// GNU gawk backend for gsub/sub operations.
/// Delegates to optimized backend for consistent behavior.
pub fn processSubstitution(
    text: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    options: AwkOptions,
    allocator: std.mem.Allocator,
) !SubstitutionResult {
    return cpu_optimized.processSubstitution(text, pattern, replacement, options, allocator);
}
