const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const GpuCapabilities = capabilities.GpuCapabilities;

/// Metal GPU capability detector.
/// Provides methods to detect GPU capabilities using Metal API.
pub const MetalDetector = struct {
    /// Stored capabilities
    caps: GpuCapabilities,

    const Self = @This();

    /// Initialize detector from thread count (the primary available attribute).
    pub fn init(max_threads: usize, device_name: ?[]const u8) Self {
        const caps = detectCapabilitiesFromThreads(max_threads, device_name);
        return Self{ .caps = caps };
    }

    /// Detect capabilities without a device handle (for testing or fallback).
    pub fn detectCapabilitiesFromThreads(max_threads: usize, device_name: ?[]const u8) GpuCapabilities {
        // Infer GPU capabilities from max threads per group.
        // This is the most reliable indicator available through zig-metal bindings.
        //
        // Apple Silicon GPUs: 1024 threads/group, high performance unified memory
        // Intel Mac GPUs: 256-512 threads/group typically
        //
        // Estimation based on max threads per group:
        // - 1024 threads: Apple Silicon (M1/M2/M3/M4 class) - estimate 8-32GB unified memory
        // - 512 threads: Mid-range GPU - estimate 4-8GB
        // - 256 threads: Entry-level - estimate 2-4GB

        const estimated_memory: u64 = if (max_threads >= 1024)
            16 * 1024 * 1024 * 1024 // 16GB for Apple Silicon
        else if (max_threads >= 512)
            8 * 1024 * 1024 * 1024 // 8GB for mid-range
        else
            4 * 1024 * 1024 * 1024; // 4GB for entry

        // Apple Silicon GPUs with 1024 threads are high-performance unified memory.
        // Treat them as "discrete" class for performance scoring since they
        // have dedicated GPU cores even though memory is shared.
        const is_high_perf = max_threads >= 1024;

        return GpuCapabilities{
            .max_threads_per_group = @intCast(max_threads),
            .max_buffer_size = 256 * 1024 * 1024, // Conservative default, actual may be higher
            .recommended_memory = estimated_memory,
            .is_discrete = is_high_perf,
            .device_type = if (is_high_perf) .discrete else .integrated,
            .device_name = device_name,
        };
    }

    /// Get detected capabilities
    pub fn getCapabilities(self: Self) GpuCapabilities {
        return self.caps;
    }
};

/// Convenience function to detect Metal capabilities from thread count.
/// Use this when you have a zig-metal pipeline and want capabilities.
pub fn detectFromThreadCount(max_threads: usize, device_name: ?[]const u8) GpuCapabilities {
    return MetalDetector.detectCapabilitiesFromThreads(max_threads, device_name);
}

/// Check if Metal is likely available on this platform.
/// Note: This is a compile-time check. Runtime availability should be
/// verified by attempting to create a Metal device.
pub fn isMetalPlatform() bool {
    return @import("builtin").os.tag == .macos;
}

test "metal capability detection" {
    const testing = std.testing;

    // Apple Silicon class (1024 threads)
    const apple_silicon = detectFromThreadCount(1024, "Apple M1 Max");
    try testing.expectEqual(@as(u32, 1024), apple_silicon.max_threads_per_group);
    try testing.expect(apple_silicon.is_discrete);
    try testing.expectEqual(GpuCapabilities.DeviceType.discrete, apple_silicon.device_type);
    try testing.expect(apple_silicon.performanceScore() >= 70); // Should be high tier

    // Intel Mac class (256 threads)
    const intel_mac = detectFromThreadCount(256, "Intel HD Graphics");
    try testing.expectEqual(@as(u32, 256), intel_mac.max_threads_per_group);
    try testing.expect(!intel_mac.is_discrete);
    try testing.expectEqual(GpuCapabilities.DeviceType.integrated, intel_mac.device_type);
    try testing.expect(intel_mac.performanceScore() < 40); // Should be entry tier
}
