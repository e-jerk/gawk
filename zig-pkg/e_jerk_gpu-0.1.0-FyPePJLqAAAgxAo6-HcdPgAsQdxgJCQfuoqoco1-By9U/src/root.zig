// GPU Capability Detection and Auto-Selection Library
//
// A reusable library for detecting GPU capabilities and automatically
// selecting the optimal compute backend (CPU, Metal, Vulkan, etc.)
// based on hardware characteristics and workload properties.
//
// Designed for use with GPU-accelerated ports of GNU utilities.
//
// Usage:
//   const gpu = @import("binoculars_gpu");
//
//   // Detect capabilities from Metal
//   const caps = gpu.metal.detectFromThreadCount(1024, "Apple M1 Max");
//
//   // Create auto-selector with hardware capabilities
//   var selector = gpu.AutoSelector.initWithCapabilities(caps);
//
//   // Select backend for workload
//   const result = selector.select(.{
//       .data_size = file_size,
//       .compute_intensity = 0.7,
//   });
//
//   if (result.backend == .metal) {
//       // Use Metal backend
//   }
//
// Swappable Backend Usage:
//   // Create a backend registry
//   var registry = gpu.BackendRegistry.init(allocator);
//   defer registry.deinit();
//
//   // Register backends (implementations provided by tools)
//   try registry.register(my_metal_backend);
//   try registry.register(my_vulkan_backend);
//
//   // Get best backend automatically
//   const backend = registry.getBestBackend();

const std = @import("std");

// Core types
pub const capabilities = @import("capabilities.zig");
pub const GpuCapabilities = capabilities.GpuCapabilities;
pub const Tier = capabilities.Tier;
pub const Backend = capabilities.Backend;

// Backend-specific detection
pub const metal = @import("metal.zig");
pub const vulkan = @import("vulkan.zig");

// Auto-selection
pub const auto_select = @import("auto_select.zig");
pub const AutoSelector = auto_select.AutoSelector;
pub const AutoSelectConfig = auto_select.AutoSelectConfig;
pub const WorkloadInfo = auto_select.WorkloadInfo;
pub const SelectionResult = auto_select.SelectionResult;

// Swappable backend interface
pub const backend = @import("backend.zig");
pub const ComputeBackend = backend.ComputeBackend;
pub const BackendRegistry = backend.BackendRegistry;
pub const BufferHandle = backend.BufferHandle;
pub const ComputeResult = backend.ComputeResult;
pub const CpuBackend = backend.CpuBackend;

// Convenience functions
pub const selectBackend = auto_select.selectBackend;
pub const quickSelect = auto_select.quickSelect;

/// Library version
pub const version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 0,
};

test {
    // Run all tests
    std.testing.refAllDecls(@This());
}
