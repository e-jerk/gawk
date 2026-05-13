const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const GpuCapabilities = capabilities.GpuCapabilities;
pub const Backend = capabilities.Backend;
pub const Tier = capabilities.Tier;

/// Workload characteristics that influence backend selection.
/// Tools should populate this with information about the current operation.
pub const WorkloadInfo = struct {
    /// Size of data to process in bytes
    data_size: usize,
    /// Estimated compute intensity (higher = more GPU-friendly)
    /// Range: 0.0 (trivial) to 1.0 (very compute intensive)
    compute_intensity: f32 = 0.5,
    /// Whether the operation benefits from parallelism
    /// (e.g., embarrassingly parallel vs sequential dependencies)
    parallelizable: bool = true,
    /// Whether the operation is memory-bound vs compute-bound
    memory_bound: bool = false,
    /// Number of independent operations (for batching)
    batch_size: usize = 1,
    /// Custom GPU score adjustment (-10 to +10)
    custom_bias: i32 = 0,
};

/// Configuration for auto-selection thresholds.
/// These can be adjusted based on hardware or user preferences.
pub const AutoSelectConfig = struct {
    /// Minimum data size for GPU consideration
    min_gpu_size: usize = 128 * 1024, // 128KB default
    /// Maximum data size for GPU (buffer limits)
    max_gpu_size: usize = 16 * 1024 * 1024, // 16MB default
    /// Base GPU score adjustment (from hardware detection or user override)
    gpu_bias: i32 = 0,
    /// Whether hardware-based adjustments have been applied
    hardware_adjusted: bool = false,
    /// Preferred GPU backend (metal, vulkan, or null for auto)
    preferred_gpu_backend: ?Backend = null,

    /// Apply hardware-based adjustments from detected GPU capabilities.
    pub fn applyHardwareCapabilities(self: *AutoSelectConfig, caps: GpuCapabilities) void {
        if (self.hardware_adjusted) return;

        // Adjust GPU bias based on hardware performance score
        self.gpu_bias += caps.gpuBiasAdjustment();

        // Adjust min size based on GPU tier
        self.min_gpu_size = caps.minGpuWorkloadSize();

        // Adjust max size based on actual buffer limits
        self.max_gpu_size = caps.maxGpuWorkloadSize(self.max_gpu_size);

        self.hardware_adjusted = true;
    }

    /// Reset to defaults
    pub fn reset(self: *AutoSelectConfig) void {
        self.* = AutoSelectConfig{};
    }
};

/// Auto-selector that chooses the optimal backend for a workload.
pub const AutoSelector = struct {
    config: AutoSelectConfig,
    caps: ?GpuCapabilities,

    const Self = @This();

    /// Create selector with default configuration
    pub fn init() Self {
        return Self{
            .config = AutoSelectConfig{},
            .caps = null,
        };
    }

    /// Create selector with custom configuration
    pub fn initWithConfig(config: AutoSelectConfig) Self {
        return Self{
            .config = config,
            .caps = null,
        };
    }

    /// Create selector with hardware capabilities
    pub fn initWithCapabilities(caps: GpuCapabilities) Self {
        var config = AutoSelectConfig{};
        config.applyHardwareCapabilities(caps);
        return Self{
            .config = config,
            .caps = caps,
        };
    }

    /// Select the optimal backend for a workload.
    /// Returns the recommended backend and a score indicating confidence.
    pub fn select(self: Self, workload: WorkloadInfo) SelectionResult {
        return doSelectBackend(workload, self.config);
    }

    /// Simple selection that just returns the backend
    pub fn selectSimple(self: Self, workload: WorkloadInfo) Backend {
        return self.select(workload).backend;
    }

    /// Get current configuration
    pub fn getConfig(self: Self) AutoSelectConfig {
        return self.config;
    }

    /// Update configuration
    pub fn setConfig(self: *Self, config: AutoSelectConfig) void {
        self.config = config;
    }
};

/// Result of backend selection
pub const SelectionResult = struct {
    backend: Backend,
    /// Score indicating GPU advantage (positive = GPU better, negative = CPU better)
    gpu_score: i32,
    /// Human-readable reason for selection
    reason: []const u8,
};

/// Core backend selection algorithm.
/// This implements the scoring heuristics for choosing CPU vs GPU.
pub fn doSelectBackend(workload: WorkloadInfo, config: AutoSelectConfig) SelectionResult {
    var gpu_score: i32 = config.gpu_bias;
    var reason: []const u8 = "default";

    // Hard limits - data size
    if (workload.data_size < config.min_gpu_size) {
        return SelectionResult{
            .backend = .cpu,
            .gpu_score = -100,
            .reason = "data too small for GPU",
        };
    }
    if (workload.data_size > config.max_gpu_size) {
        return SelectionResult{
            .backend = .cpu,
            .gpu_score = -100,
            .reason = "data exceeds GPU buffer limit",
        };
    }

    // Base GPU advantage for parallelizable workloads
    if (workload.parallelizable) {
        gpu_score += 3;
        reason = "parallelizable workload";
    } else {
        gpu_score -= 5;
        reason = "sequential dependencies";
    }

    // Data size scoring - larger data benefits more from GPU
    if (workload.data_size >= 4 * 1024 * 1024) {
        gpu_score += 2; // >= 4MB
    } else if (workload.data_size >= 1 * 1024 * 1024) {
        gpu_score += 1; // >= 1MB
    }

    // Compute intensity scoring
    if (workload.compute_intensity >= 0.8) {
        gpu_score += 4; // High compute intensity strongly favors GPU
        reason = "high compute intensity";
    } else if (workload.compute_intensity >= 0.5) {
        gpu_score += 2;
    } else if (workload.compute_intensity < 0.2) {
        gpu_score -= 2; // Very low intensity favors CPU
        reason = "low compute intensity";
    }

    // Memory-bound operations can go either way
    if (workload.memory_bound) {
        // GPU memory bandwidth is often higher, but transfer overhead exists
        if (workload.data_size >= 1 * 1024 * 1024) {
            gpu_score += 1; // Large memory-bound ops benefit from GPU bandwidth
        } else {
            gpu_score -= 1; // Small ops have transfer overhead
        }
    }

    // Batch processing strongly favors GPU
    if (workload.batch_size >= 100) {
        gpu_score += 3;
        reason = "large batch size";
    } else if (workload.batch_size >= 10) {
        gpu_score += 1;
    }

    // Apply custom bias
    gpu_score += workload.custom_bias;

    // Decision
    if (gpu_score >= 0) {
        const gpu_backend = config.preferred_gpu_backend orelse .vulkan;
        return SelectionResult{
            .backend = gpu_backend,
            .gpu_score = gpu_score,
            .reason = reason,
        };
    }

    return SelectionResult{
        .backend = .cpu,
        .gpu_score = gpu_score,
        .reason = reason,
    };
}

/// Public alias for the core selection function
pub const selectBackend = doSelectBackend;

/// Quick selection for simple use cases
pub fn quickSelect(data_size: usize, compute_intensity: f32, caps: ?GpuCapabilities) Backend {
    var config = AutoSelectConfig{};
    if (caps) |c| {
        config.applyHardwareCapabilities(c);
    }

    const workload = WorkloadInfo{
        .data_size = data_size,
        .compute_intensity = compute_intensity,
    };

    return doSelectBackend(workload, config).backend;
}

test "basic selection" {
    const testing = std.testing;

    const config = AutoSelectConfig{};

    // Small data should use CPU
    const small = selectBackend(.{ .data_size = 1024 }, config);
    try testing.expectEqual(Backend.cpu, small.backend);

    // Large data with high compute intensity should prefer GPU
    const large_compute = selectBackend(.{
        .data_size = 2 * 1024 * 1024,
        .compute_intensity = 0.9,
    }, config);
    try testing.expect(large_compute.backend != .cpu);
}

test "hardware-adjusted selection" {
    const testing = std.testing;

    // Ultra-tier GPU should lower the threshold
    const caps = GpuCapabilities{
        .max_threads_per_group = 1024,
        .max_buffer_size = 16 * 1024 * 1024,
        .recommended_memory = 32 * 1024 * 1024 * 1024,
        .is_discrete = true,
        .device_type = .discrete,
    };

    var config = AutoSelectConfig{};
    config.applyHardwareCapabilities(caps);

    // With ultra-tier GPU, medium workloads should prefer GPU
    const medium = selectBackend(.{
        .data_size = 256 * 1024,
        .compute_intensity = 0.5,
    }, config);

    // Should have positive bias from hardware
    try testing.expect(config.gpu_bias > 0);
    // Min size should be lowered
    try testing.expect(config.min_gpu_size < 128 * 1024);
    // With high hardware bias, GPU should be preferred
    try testing.expect(medium.gpu_score > 0);
}

test "batch processing" {
    const testing = std.testing;

    const config = AutoSelectConfig{};

    // Single item at boundary might use CPU
    const single = selectBackend(.{
        .data_size = 200 * 1024,
        .compute_intensity = 0.3,
        .batch_size = 1,
    }, config);

    // Large batch should strongly prefer GPU
    const batched = selectBackend(.{
        .data_size = 200 * 1024,
        .compute_intensity = 0.3,
        .batch_size = 100,
    }, config);

    try testing.expect(batched.gpu_score > single.gpu_score);
}
