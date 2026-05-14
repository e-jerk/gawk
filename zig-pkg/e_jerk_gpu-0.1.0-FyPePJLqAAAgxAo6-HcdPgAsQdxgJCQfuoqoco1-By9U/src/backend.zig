const std = @import("std");
const capabilities = @import("capabilities.zig");

pub const GpuCapabilities = capabilities.GpuCapabilities;
pub const Backend = capabilities.Backend;

/// Compute buffer handle - opaque type representing GPU memory.
pub const BufferHandle = struct {
    /// Backend-specific handle (pointer to implementation data)
    ptr: *anyopaque,
    /// Size of the buffer in bytes
    size: usize,
    /// Backend that owns this buffer
    backend: Backend,
};

/// Result of a compute operation
pub const ComputeResult = struct {
    /// Whether the operation succeeded
    success: bool,
    /// Error message if failed
    error_message: ?[]const u8 = null,
    /// Execution time in nanoseconds (if available)
    execution_time_ns: ?u64 = null,
};

/// Common interface for compute backends.
/// Implementations provide backend-specific functionality (Metal, Vulkan, etc.)
/// while tools use this common interface.
pub const ComputeBackend = struct {
    /// Backend type
    backend_type: Backend,
    /// Detected capabilities
    capabilities: GpuCapabilities,
    /// Implementation-specific data
    impl: *anyopaque,
    /// VTable for backend operations
    vtable: *const VTable,

    const Self = @This();

    pub const VTable = struct {
        /// Allocate a buffer on the GPU
        allocBuffer: *const fn (self: *anyopaque, size: usize) anyerror!BufferHandle,
        /// Free a buffer
        freeBuffer: *const fn (self: *anyopaque, buffer: BufferHandle) void,
        /// Copy data from host to device buffer
        uploadData: *const fn (self: *anyopaque, buffer: BufferHandle, data: []const u8) anyerror!void,
        /// Copy data from device buffer to host
        downloadData: *const fn (self: *anyopaque, buffer: BufferHandle, out: []u8) anyerror!void,
        /// Execute a compute shader/kernel
        dispatch: *const fn (self: *anyopaque, workgroups: [3]u32, bindings: []const BufferHandle) anyerror!ComputeResult,
        /// Wait for all pending operations to complete
        synchronize: *const fn (self: *anyopaque) anyerror!void,
        /// Cleanup and release resources
        deinit: *const fn (self: *anyopaque) void,
    };

    /// Allocate a buffer on the GPU
    pub fn allocBuffer(self: Self, size: usize) !BufferHandle {
        return self.vtable.allocBuffer(self.impl, size);
    }

    /// Free a buffer
    pub fn freeBuffer(self: Self, buffer: BufferHandle) void {
        self.vtable.freeBuffer(self.impl, buffer);
    }

    /// Copy data from host to device buffer
    pub fn uploadData(self: Self, buffer: BufferHandle, data: []const u8) !void {
        return self.vtable.uploadData(self.impl, buffer, data);
    }

    /// Copy data from device buffer to host
    pub fn downloadData(self: Self, buffer: BufferHandle, out: []u8) !void {
        return self.vtable.downloadData(self.impl, buffer, out);
    }

    /// Execute a compute shader/kernel
    pub fn dispatch(self: Self, workgroups: [3]u32, bindings: []const BufferHandle) !ComputeResult {
        return self.vtable.dispatch(self.impl, workgroups, bindings);
    }

    /// Wait for all pending operations to complete
    pub fn synchronize(self: Self) !void {
        return self.vtable.synchronize(self.impl);
    }

    /// Cleanup and release resources
    pub fn deinit(self: Self) void {
        self.vtable.deinit(self.impl);
    }

    /// Get backend type
    pub fn getType(self: Self) Backend {
        return self.backend_type;
    }

    /// Get capabilities
    pub fn getCapabilities(self: Self) GpuCapabilities {
        return self.capabilities;
    }

    /// Check if this is a GPU backend
    pub fn isGpu(self: Self) bool {
        return self.backend_type != .cpu;
    }
};

/// Backend registry for managing multiple backends.
/// Allows automatic backend selection and fallback.
pub const BackendRegistry = struct {
    /// Registered backends (in priority order)
    backends: std.ArrayListUnmanaged(ComputeBackend) = .{},
    /// Allocator used for the registry
    allocator: std.mem.Allocator,
    /// Currently selected backend
    current: ?*ComputeBackend = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.backends.items) |*b| {
            b.deinit();
        }
        self.backends.deinit(self.allocator);
    }

    /// Register a backend
    pub fn register(self: *Self, b: ComputeBackend) !void {
        try self.backends.append(self.allocator, b);
    }

    /// Get the best available backend based on capabilities
    pub fn getBestBackend(self: *Self) ?*ComputeBackend {
        if (self.backends.items.len == 0) return null;

        var best: ?*ComputeBackend = null;
        var best_score: u32 = 0;

        for (self.backends.items) |*backend| {
            const score = backend.capabilities.performanceScore();
            if (best == null or score > best_score) {
                best = backend;
                best_score = score;
            }
        }

        return best;
    }

    /// Get a specific backend by type
    pub fn getBackend(self: *Self, backend_type: Backend) ?*ComputeBackend {
        for (self.backends.items) |*backend| {
            if (backend.backend_type == backend_type) {
                return backend;
            }
        }
        return null;
    }

    /// Get or select the current backend
    pub fn getCurrent(self: *Self) ?*ComputeBackend {
        if (self.current) |c| return c;
        self.current = self.getBestBackend();
        return self.current;
    }

    /// Set the current backend
    pub fn setCurrent(self: *Self, backend_type: Backend) bool {
        if (self.getBackend(backend_type)) |b| {
            self.current = b;
            return true;
        }
        return false;
    }
};

/// CPU fallback backend implementation.
/// Always available, provides baseline implementation.
pub const CpuBackend = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    pub fn toComputeBackend(self: *Self) ComputeBackend {
        return ComputeBackend{
            .backend_type = .cpu,
            .capabilities = GpuCapabilities{
                .max_threads_per_group = 1,
                .max_buffer_size = std.math.maxInt(u32),
                .recommended_memory = 0, // Not applicable for CPU
                .is_discrete = false,
                .device_type = .cpu,
            },
            .impl = self,
            .vtable = &vtable,
        };
    }

    const vtable = VTable{
        .allocBuffer = allocBuffer,
        .freeBuffer = freeBuffer,
        .uploadData = uploadData,
        .downloadData = downloadData,
        .dispatch = dispatch,
        .synchronize = synchronize,
        .deinit = deinitFn,
    };

    const VTable = ComputeBackend.VTable;

    fn allocBuffer(ptr: *anyopaque, size: usize) anyerror!BufferHandle {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const mem = try self.allocator.alloc(u8, size);
        return BufferHandle{
            .ptr = @ptrCast(mem.ptr),
            .size = size,
            .backend = .cpu,
        };
    }

    fn freeBuffer(ptr: *anyopaque, buffer: BufferHandle) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const slice: []u8 = @as([*]u8, @ptrCast(buffer.ptr))[0..buffer.size];
        self.allocator.free(slice);
    }

    fn uploadData(_: *anyopaque, buffer: BufferHandle, data: []const u8) anyerror!void {
        const dest: [*]u8 = @ptrCast(buffer.ptr);
        @memcpy(dest[0..data.len], data);
    }

    fn downloadData(_: *anyopaque, buffer: BufferHandle, out: []u8) anyerror!void {
        const src: [*]const u8 = @ptrCast(buffer.ptr);
        @memcpy(out, src[0..out.len]);
    }

    fn dispatch(_: *anyopaque, _: [3]u32, _: []const BufferHandle) anyerror!ComputeResult {
        // CPU backend doesn't support generic compute dispatch
        // Tools should implement their own CPU fallback logic
        return ComputeResult{
            .success = false,
            .error_message = "CPU backend requires tool-specific implementation",
        };
    }

    fn synchronize(_: *anyopaque) anyerror!void {
        // CPU is always synchronous
    }

    fn deinitFn(_: *anyopaque) void {
        // Nothing to clean up for CPU backend
    }
};

test "cpu backend buffer operations" {
    const testing = std.testing;

    var cpu = CpuBackend.init(testing.allocator);
    const backend = cpu.toComputeBackend();

    // Allocate buffer
    const buffer = try backend.allocBuffer(1024);
    defer backend.freeBuffer(buffer);

    try testing.expectEqual(@as(usize, 1024), buffer.size);
    try testing.expectEqual(Backend.cpu, buffer.backend);

    // Upload and download data
    const test_data = "Hello, GPU!";
    try backend.uploadData(buffer, test_data);

    var downloaded: [11]u8 = undefined;
    try backend.downloadData(buffer, &downloaded);
    try testing.expectEqualStrings(test_data, &downloaded);
}

test "backend registry" {
    const testing = std.testing;

    var registry = BackendRegistry.init(testing.allocator);
    defer registry.deinit();

    var cpu = CpuBackend.init(testing.allocator);
    try registry.register(cpu.toComputeBackend());

    // Should find CPU backend
    try testing.expect(registry.getBackend(.cpu) != null);
    try testing.expect(registry.getBackend(.metal) == null);

    // Current should default to best (CPU in this case)
    const current = registry.getCurrent();
    try testing.expect(current != null);
    try testing.expectEqual(Backend.cpu, current.?.backend_type);
}
