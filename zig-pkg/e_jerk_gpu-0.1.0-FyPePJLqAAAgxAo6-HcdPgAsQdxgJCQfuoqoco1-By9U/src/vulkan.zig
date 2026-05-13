const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const GpuCapabilities = capabilities.GpuCapabilities;

/// Vulkan device type mapping (mirrors VkPhysicalDeviceType)
pub const VulkanDeviceType = enum(u32) {
    other = 0,
    integrated_gpu = 1,
    discrete_gpu = 2,
    virtual_gpu = 3,
    cpu = 4,

    pub fn toDeviceType(self: VulkanDeviceType) GpuCapabilities.DeviceType {
        return switch (self) {
            .discrete_gpu => .discrete,
            .integrated_gpu => .integrated,
            .virtual_gpu => .virtual,
            .cpu => .cpu,
            .other => .other,
        };
    }

    pub fn isDiscrete(self: VulkanDeviceType) bool {
        return self == .discrete_gpu;
    }
};

/// Vulkan device properties needed for capability detection.
/// This struct can be populated from VkPhysicalDeviceProperties.
pub const VulkanDeviceProperties = struct {
    /// Device type (discrete, integrated, etc.)
    device_type: VulkanDeviceType,
    /// Max compute work group invocations (from limits)
    max_compute_work_group_invocations: u32,
    /// Max storage buffer range (from limits)
    max_storage_buffer_range: u32,
    /// Device name (optional)
    device_name: ?[]const u8 = null,
};

/// Vulkan memory heap info needed for capability detection.
/// This struct represents a single memory heap from VkPhysicalDeviceMemoryProperties.
pub const VulkanMemoryHeap = struct {
    /// Heap size in bytes
    size: u64,
    /// Whether this heap is device local
    is_device_local: bool,
};

/// Vulkan GPU capability detector.
/// Provides methods to detect GPU capabilities using Vulkan API data.
pub const VulkanDetector = struct {
    caps: GpuCapabilities,

    const Self = @This();

    /// Detect capabilities from Vulkan device properties and memory info.
    ///
    /// Parameters:
    ///   props: Device properties from vkGetPhysicalDeviceProperties
    ///   memory_heaps: Slice of memory heaps from vkGetPhysicalDeviceMemoryProperties
    pub fn detect(props: VulkanDeviceProperties, memory_heaps: []const VulkanMemoryHeap) Self {
        // Calculate total device local memory
        var device_local_memory: u64 = 0;
        for (memory_heaps) |heap| {
            if (heap.is_device_local) {
                device_local_memory += heap.size;
            }
        }

        const is_discrete = props.device_type.isDiscrete();

        const caps = GpuCapabilities{
            .max_threads_per_group = props.max_compute_work_group_invocations,
            .max_buffer_size = props.max_storage_buffer_range,
            .recommended_memory = device_local_memory,
            .is_discrete = is_discrete,
            .device_type = props.device_type.toDeviceType(),
            .device_name = props.device_name,
        };

        return Self{ .caps = caps };
    }

    /// Detect capabilities with just device properties (no memory info).
    /// Memory will be estimated based on device type and thread count.
    pub fn detectFromPropertiesOnly(props: VulkanDeviceProperties) Self {
        const is_discrete = props.device_type.isDiscrete();

        // Estimate memory based on device type and compute capabilities
        const estimated_memory: u64 = if (is_discrete)
            8 * 1024 * 1024 * 1024 // 8GB for discrete
        else if (props.max_compute_work_group_invocations >= 1024)
            16 * 1024 * 1024 * 1024 // 16GB for high-perf integrated (Apple Silicon via MoltenVK)
        else
            4 * 1024 * 1024 * 1024; // 4GB for basic integrated

        const caps = GpuCapabilities{
            .max_threads_per_group = props.max_compute_work_group_invocations,
            .max_buffer_size = props.max_storage_buffer_range,
            .recommended_memory = estimated_memory,
            .is_discrete = is_discrete,
            .device_type = props.device_type.toDeviceType(),
            .device_name = props.device_name,
        };

        return Self{ .caps = caps };
    }

    /// Get detected capabilities
    pub fn getCapabilities(self: Self) GpuCapabilities {
        return self.caps;
    }
};

/// Convenience function to detect Vulkan capabilities from properties and memory.
pub fn detectCapabilities(props: VulkanDeviceProperties, memory_heaps: []const VulkanMemoryHeap) GpuCapabilities {
    return VulkanDetector.detect(props, memory_heaps).getCapabilities();
}

/// Convenience function to detect Vulkan capabilities from properties only.
pub fn detectCapabilitiesFromProperties(props: VulkanDeviceProperties) GpuCapabilities {
    return VulkanDetector.detectFromPropertiesOnly(props).getCapabilities();
}

/// Score a device for selection (higher is better).
/// Useful when choosing between multiple Vulkan devices.
pub fn scoreDeviceForSelection(props: VulkanDeviceProperties) u32 {
    var score: u32 = 0;

    // Discrete GPUs are strongly preferred
    switch (props.device_type) {
        .discrete_gpu => score += 1000,
        .integrated_gpu => score += 100,
        .virtual_gpu => score += 10,
        .cpu => score += 1,
        .other => score += 0,
    }

    // More compute capability is better
    score += props.max_compute_work_group_invocations / 100;

    // Larger buffer support is better
    score += @as(u32, @intCast(props.max_storage_buffer_range / (1024 * 1024)));

    return score;
}

test "vulkan capability detection" {
    const testing = std.testing;

    // Discrete GPU with good memory
    const discrete_props = VulkanDeviceProperties{
        .device_type = .discrete_gpu,
        .max_compute_work_group_invocations = 1024,
        .max_storage_buffer_range = 2 * 1024 * 1024 * 1024, // 2GB
        .device_name = "NVIDIA RTX 3080",
    };
    const discrete_heaps = [_]VulkanMemoryHeap{
        .{ .size = 10 * 1024 * 1024 * 1024, .is_device_local = true },
        .{ .size = 16 * 1024 * 1024 * 1024, .is_device_local = false },
    };

    const discrete_caps = detectCapabilities(discrete_props, &discrete_heaps);
    try testing.expect(discrete_caps.is_discrete);
    try testing.expectEqual(@as(u64, 10 * 1024 * 1024 * 1024), discrete_caps.recommended_memory);
    try testing.expect(discrete_caps.performanceScore() >= 70);

    // Integrated GPU
    const integrated_props = VulkanDeviceProperties{
        .device_type = .integrated_gpu,
        .max_compute_work_group_invocations = 512,
        .max_storage_buffer_range = 256 * 1024 * 1024,
        .device_name = "Intel UHD Graphics",
    };
    const integrated_heaps = [_]VulkanMemoryHeap{
        .{ .size = 2 * 1024 * 1024 * 1024, .is_device_local = true },
    };

    const integrated_caps = detectCapabilities(integrated_props, &integrated_heaps);
    try testing.expect(!integrated_caps.is_discrete);
    try testing.expect(integrated_caps.performanceScore() < 70);
}

test "device selection scoring" {
    const testing = std.testing;

    const discrete = VulkanDeviceProperties{
        .device_type = .discrete_gpu,
        .max_compute_work_group_invocations = 1024,
        .max_storage_buffer_range = 2 * 1024 * 1024 * 1024,
    };

    const integrated = VulkanDeviceProperties{
        .device_type = .integrated_gpu,
        .max_compute_work_group_invocations = 512,
        .max_storage_buffer_range = 256 * 1024 * 1024,
    };

    // Discrete should score much higher
    try testing.expect(scoreDeviceForSelection(discrete) > scoreDeviceForSelection(integrated));
}
