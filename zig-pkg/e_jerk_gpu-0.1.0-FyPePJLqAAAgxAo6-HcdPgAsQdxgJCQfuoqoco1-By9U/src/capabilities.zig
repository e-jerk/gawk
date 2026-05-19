const std = @import("std");

/// GPU hardware capabilities detected at runtime from actual device attributes.
/// This struct is backend-agnostic and can be populated from Metal, Vulkan, or other APIs.
pub const GpuCapabilities = struct {
    /// Maximum threads per threadgroup/workgroup
    max_threads_per_group: u32,
    /// Maximum buffer size in bytes
    max_buffer_size: u64,
    /// Recommended working set size (Metal) or device local memory (Vulkan)
    recommended_memory: u64,
    /// Whether this is a discrete (dedicated) GPU vs integrated
    is_discrete: bool,
    /// Device type classification
    device_type: DeviceType,
    /// Optional device name for logging
    device_name: ?[]const u8 = null,

    pub const DeviceType = enum {
        discrete,
        integrated,
        virtual,
        cpu,
        other,
    };

    /// Calculate a performance score based on hardware attributes.
    /// Higher score = better GPU, more suitable for GPU acceleration.
    /// Score ranges roughly:
    ///   0-40: Entry tier (integrated, low-end discrete)
    ///   40-70: Mid tier (mainstream discrete)
    ///   70-100: High tier (high-end discrete, Apple Silicon Pro/Max)
    ///   100+: Ultra tier (workstation, Apple Silicon Ultra)
    pub fn performanceScore(self: GpuCapabilities) u32 {
        var score: u32 = 0;

        // Discrete GPUs get a significant boost
        if (self.is_discrete) score += 50;

        // More threads = more parallelism
        if (self.max_threads_per_group >= 1024) {
            score += 30;
        } else if (self.max_threads_per_group >= 512) {
            score += 20;
        } else if (self.max_threads_per_group >= 256) {
            score += 10;
        }

        // More memory = can handle larger workloads efficiently
        const mem_gb = self.recommended_memory / (1024 * 1024 * 1024);
        if (mem_gb >= 16) {
            score += 30;
        } else if (mem_gb >= 8) {
            score += 20;
        } else if (mem_gb >= 4) {
            score += 10;
        } else if (mem_gb >= 2) {
            score += 5;
        }

        // Large buffer support
        const buf_gb = self.max_buffer_size / (1024 * 1024 * 1024);
        if (buf_gb >= 4) {
            score += 10;
        } else if (buf_gb >= 1) {
            score += 5;
        }

        return score;
    }

    /// Get the performance tier based on score
    pub fn tier(self: GpuCapabilities) Tier {
        const score = self.performanceScore();
        if (score >= 100) return .ultra;
        if (score >= 70) return .high;
        if (score >= 40) return .mid;
        return .entry;
    }

    /// Get GPU bias adjustment based on performance score.
    /// Used to adjust auto-selection thresholds.
    pub fn gpuBiasAdjustment(self: GpuCapabilities) i32 {
        return switch (self.tier()) {
            .ultra => 4, // Strong GPU preference
            .high => 2, // Moderate GPU preference
            .mid => 0, // Neutral
            .entry => -2, // Reduce GPU preference
        };
    }

    /// Get recommended minimum file/data size for GPU based on hardware.
    /// Better GPUs can efficiently process smaller workloads.
    pub fn minGpuWorkloadSize(self: GpuCapabilities) usize {
        return switch (self.tier()) {
            .ultra => 32 * 1024, // 32KB
            .high => 64 * 1024, // 64KB
            .mid => 128 * 1024, // 128KB
            .entry => 256 * 1024, // 256KB
        };
    }

    /// Get recommended maximum file/data size for GPU based on buffer limits.
    /// Returns the smaller of 75% of max buffer or provided limit.
    pub fn maxGpuWorkloadSize(self: GpuCapabilities, hard_limit: usize) usize {
        // Use 75% of max buffer size to leave room for other buffers
        const max = self.max_buffer_size * 3 / 4;
        return @min(max, hard_limit);
    }

    /// Default capabilities for when detection fails
    pub const default = GpuCapabilities{
        .max_threads_per_group = 256,
        .max_buffer_size = 256 * 1024 * 1024, // 256MB
        .recommended_memory = 4 * 1024 * 1024 * 1024, // 4GB
        .is_discrete = false,
        .device_type = .other,
    };
};

/// Performance tier classification
pub const Tier = enum {
    /// Entry-level: Intel/AMD integrated, base Apple Silicon
    /// ~2-4 TFLOPS, suitable but not optimal for GPU acceleration
    entry,

    /// Mid-range: Apple Silicon Pro, mainstream discrete GPUs
    /// ~5-8 TFLOPS, good GPU acceleration
    mid,

    /// High-end: Apple Silicon Max, high-end discrete GPUs
    /// ~10-25 TFLOPS, excellent GPU acceleration
    high,

    /// Enthusiast: Apple Silicon Ultra, workstation GPUs
    /// ~25+ TFLOPS, maximum GPU acceleration
    ultra,

    pub fn name(self: Tier) []const u8 {
        return switch (self) {
            .entry => "Entry",
            .mid => "Mid",
            .high => "High",
            .ultra => "Ultra",
        };
    }
};

/// Backend selection
pub const Backend = enum {
    cpu,
    metal,
    vulkan,
    cuda,
    opencl,

    pub fn isGpu(self: Backend) bool {
        return self != .cpu;
    }
};

test "performance score calculation" {
    const testing = std.testing;

    // Entry-level integrated GPU
    const entry = GpuCapabilities{
        .max_threads_per_group = 256,
        .max_buffer_size = 256 * 1024 * 1024,
        .recommended_memory = 2 * 1024 * 1024 * 1024,
        .is_discrete = false,
        .device_type = .integrated,
    };
    try testing.expect(entry.performanceScore() < 40);
    try testing.expectEqual(Tier.entry, entry.tier());

    // High-end discrete GPU (like Apple Silicon Max)
    const high = GpuCapabilities{
        .max_threads_per_group = 1024,
        .max_buffer_size = 4 * 1024 * 1024 * 1024,
        .recommended_memory = 32 * 1024 * 1024 * 1024,
        .is_discrete = true,
        .device_type = .discrete,
    };
    try testing.expect(high.performanceScore() >= 100);
    try testing.expectEqual(Tier.ultra, high.tier());
}

test "workload size recommendations" {
    const testing = std.testing;

    const caps = GpuCapabilities{
        .max_threads_per_group = 1024,
        .max_buffer_size = 16 * 1024 * 1024, // 16MB
        .recommended_memory = 16 * 1024 * 1024 * 1024,
        .is_discrete = true,
        .device_type = .discrete,
    };

    // Ultra tier should have small minimum
    try testing.expectEqual(@as(usize, 32 * 1024), caps.minGpuWorkloadSize());

    // Max should be 75% of buffer or hard limit
    try testing.expectEqual(@as(usize, 12 * 1024 * 1024), caps.maxGpuWorkloadSize(100 * 1024 * 1024));
}
