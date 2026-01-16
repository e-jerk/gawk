const std = @import("std");
const mtl = @import("zig-metal");
const mod = @import("mod.zig");
const regex_compiler = @import("regex_compiler.zig");
const regex_lib = @import("regex");

const AwkConfig = mod.AwkConfig;
const AwkMatchResult = mod.AwkMatchResult;
const AwkRegexConfig = mod.AwkRegexConfig;
const RegexState = mod.RegexState;
const FieldInfo = mod.FieldInfo;
const AwkOptions = mod.AwkOptions;
const AwkResult = mod.AwkResult;
const EMBEDDED_METAL_SHADER = mod.EMBEDDED_METAL_SHADER;
const MAX_RESULTS = mod.MAX_RESULTS;
const MAX_FIELDS = mod.MAX_FIELDS;
const MAX_GPU_BUFFER_SIZE = mod.MAX_GPU_BUFFER_SIZE;

// Access low-level Metal device methods for memory queries
const DeviceMixin = mtl.gen.MTLDeviceProtocolMixin(mtl.gen.MTLDevice, "MTLDevice");

pub const MetalAwk = struct {
    device: mtl.MTLDevice,
    command_queue: mtl.MTLCommandQueue,
    pattern_match_pipeline: mtl.MTLComputePipelineState,
    field_split_pipeline: mtl.MTLComputePipelineState,
    regex_match_pipeline: mtl.MTLComputePipelineState,
    allocator: std.mem.Allocator,
    threads_per_group: usize,
    capabilities: mod.GpuCapabilities,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const device = mtl.createSystemDefaultDevice() orelse return error.NoMetalDevice;
        errdefer device.release();

        const command_queue = device.newCommandQueue() orelse return error.NoCommandQueue;
        errdefer command_queue.release();

        const source_ns = mtl.NSString.stringWithUTF8String(EMBEDDED_METAL_SHADER.ptr);
        var library = device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse return error.ShaderCompileFailed;
        defer library.release();

        // Pattern matching kernel
        const match_func_name = mtl.NSString.stringWithUTF8String("awk_pattern_match");
        var match_func = library.newFunctionWithName(match_func_name) orelse return error.FunctionNotFound;
        defer match_func.release();

        var pattern_match_pipeline = device.newComputePipelineStateWithFunctionError(match_func, null) orelse return error.PipelineCreationFailed;

        // Field split kernel
        const split_func_name = mtl.NSString.stringWithUTF8String("awk_field_split");
        var split_func = library.newFunctionWithName(split_func_name) orelse return error.FunctionNotFound;
        defer split_func.release();

        const field_split_pipeline = device.newComputePipelineStateWithFunctionError(split_func, null) orelse return error.PipelineCreationFailed;

        // Regex match kernel
        const regex_func_name = mtl.NSString.stringWithUTF8String("awk_regex_match");
        var regex_func = library.newFunctionWithName(regex_func_name) orelse return error.FunctionNotFound;
        defer regex_func.release();

        const regex_match_pipeline = device.newComputePipelineStateWithFunctionError(regex_func, null) orelse return error.PipelineCreationFailed;

        // Query hardware attributes
        const max_threads = pattern_match_pipeline.maxTotalThreadsPerThreadgroup();
        const threads_to_use: usize = @min(256, max_threads);

        // Query actual memory from Metal API
        const recommended_memory = DeviceMixin.recommendedMaxWorkingSetSize(device.ptr);
        const max_buffer_len = DeviceMixin.maxBufferLength(device.ptr);
        const has_unified = DeviceMixin.hasUnifiedMemory(device.ptr) != 0;

        const is_high_perf = has_unified and max_threads >= 1024;

        const capabilities = mod.GpuCapabilities{
            .max_threads_per_group = @intCast(max_threads),
            .max_buffer_size = @min(max_buffer_len, MAX_GPU_BUFFER_SIZE),
            .recommended_memory = recommended_memory,
            .is_discrete = is_high_perf,
            .device_type = if (is_high_perf) .discrete else .integrated,
        };

        const self = try allocator.create(Self);
        self.* = Self{
            .device = device,
            .command_queue = command_queue,
            .pattern_match_pipeline = pattern_match_pipeline,
            .field_split_pipeline = field_split_pipeline,
            .regex_match_pipeline = regex_match_pipeline,
            .allocator = allocator,
            .threads_per_group = threads_to_use,
            .capabilities = capabilities,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.regex_match_pipeline.release();
        self.field_split_pipeline.release();
        self.pattern_match_pipeline.release();
        self.command_queue.release();
        self.device.release();
        self.allocator.destroy(self);
    }

    pub fn processAwk(self: *Self, text: []const u8, pattern: []const u8, options: AwkOptions, allocator: std.mem.Allocator) !AwkResult {
        if (text.len > MAX_GPU_BUFFER_SIZE) return error.TextTooLarge;

        // First pass: find line boundaries on CPU (simpler for now)
        var line_offsets: std.ArrayListUnmanaged(u32) = .{};
        defer line_offsets.deinit(allocator);
        var line_lengths: std.ArrayListUnmanaged(u32) = .{};
        defer line_lengths.deinit(allocator);

        var line_start: usize = 0;
        for (text, 0..) |c, i| {
            if (c == '\n') {
                try line_offsets.append(allocator, @intCast(line_start));
                try line_lengths.append(allocator, @intCast(i - line_start));
                line_start = i + 1;
            }
        }
        // Handle last line without newline
        if (line_start < text.len) {
            try line_offsets.append(allocator, @intCast(line_start));
            try line_lengths.append(allocator, @intCast(text.len - line_start));
        }

        const num_lines = line_offsets.items.len;
        if (num_lines == 0) {
            return AwkResult{
                .matches = &[_]AwkMatchResult{},
                .fields = &[_]FieldInfo{},
                .total_matches = 0,
                .total_lines = 0,
                .allocator = allocator,
            };
        }

        // Create buffers
        var text_buffer = self.device.newBufferWithLengthOptions(text.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer text_buffer.release();
        if (text_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..text.len], text);
        }

        const pattern_len = if (pattern.len > 0) pattern.len else 1;
        var pattern_buffer = self.device.newBufferWithLengthOptions(pattern_len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer pattern_buffer.release();
        if (pattern.len > 0) {
            if (pattern_buffer.contents()) |ptr| {
                @memcpy(@as([*]u8, @ptrCast(ptr))[0..pattern.len], pattern);
            }
        }

        const skip_table = if (pattern.len > 0) mod.buildSkipTable(pattern, options.case_insensitive) else [_]u8{1} ** 256;
        var skip_buffer = self.device.newBufferWithLengthOptions(256, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer skip_buffer.release();
        if (skip_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..256], &skip_table);
        }

        const config = AwkConfig{
            .text_len = @intCast(text.len),
            .pattern_len = @intCast(pattern.len),
            .field_sep_len = @intCast(options.field_separator.len),
            .num_fields_requested = @intCast(options.requested_fields.len),
            .flags = options.toFlags(),
            .max_results = MAX_RESULTS,
            .max_fields = MAX_FIELDS,
            .replacement_len = 0,
        };
        var config_buffer = self.device.newBufferWithLengthOptions(@sizeOf(AwkConfig), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer config_buffer.release();
        if (config_buffer.contents()) |ptr| {
            @as(*AwkConfig, @ptrCast(@alignCast(ptr))).* = config;
        }

        const results_size = @sizeOf(AwkMatchResult) * MAX_RESULTS;
        var results_buffer = self.device.newBufferWithLengthOptions(results_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer results_buffer.release();

        var counters_buffer = self.device.newBufferWithLengthOptions(8, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer counters_buffer.release();
        const counters_ptr: *[2]u32 = @ptrCast(@alignCast(counters_buffer.contents()));
        counters_ptr[0] = 0;
        counters_ptr[1] = 0;

        var line_offsets_buffer = self.device.newBufferWithLengthOptions(line_offsets.items.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer line_offsets_buffer.release();
        if (line_offsets_buffer.contents()) |ptr| {
            @memcpy(@as([*]u32, @ptrCast(@alignCast(ptr)))[0..line_offsets.items.len], line_offsets.items);
        }

        var line_lengths_buffer = self.device.newBufferWithLengthOptions(line_lengths.items.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer line_lengths_buffer.release();
        if (line_lengths_buffer.contents()) |ptr| {
            @memcpy(@as([*]u32, @ptrCast(@alignCast(ptr)))[0..line_lengths.items.len], line_lengths.items);
        }

        // Execute pattern matching
        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;

        encoder.setComputePipelineState(self.pattern_match_pipeline);
        encoder.setBufferOffsetAtIndex(text_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(pattern_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(skip_buffer, 0, 2);
        encoder.setBufferOffsetAtIndex(config_buffer, 0, 3);
        encoder.setBufferOffsetAtIndex(results_buffer, 0, 4);
        encoder.setBufferOffsetAtIndex(counters_buffer, 0, 5);
        encoder.setBufferOffsetAtIndex(line_offsets_buffer, 0, 6);
        encoder.setBufferOffsetAtIndex(line_lengths_buffer, 0, 7);

        const grid_size = mtl.MTLSize{ .width = num_lines, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = @min(self.threads_per_group, num_lines), .height = 1, .depth = 1 };

        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        const match_count = counters_ptr[0];

        // Copy results
        const num_to_copy = @min(match_count, MAX_RESULTS);
        const matches = try allocator.alloc(AwkMatchResult, num_to_copy);
        if (num_to_copy > 0) {
            const results_ptr: [*]AwkMatchResult = @ptrCast(@alignCast(results_buffer.contents()));
            @memcpy(matches, results_ptr[0..num_to_copy]);
        }

        // Do field splitting on CPU and update field_count for NF support
        var fields: std.ArrayListUnmanaged(FieldInfo) = .{};
        for (matches, 0..) |*match, idx| {
            const line = text[match.line_start..match.line_end];
            var field_idx: u32 = 1;
            var field_start: u32 = 0;
            var in_field = false;

            for (line, 0..) |c, i| {
                var is_sep = false;
                for (options.field_separator) |s| {
                    if (c == s) {
                        is_sep = true;
                        break;
                    }
                }

                if (!is_sep and !in_field) {
                    in_field = true;
                    field_start = @intCast(i);
                } else if (is_sep and in_field) {
                    try fields.append(allocator, .{
                        .line_idx = @intCast(idx),
                        .field_idx = field_idx,
                        .start_offset = field_start,
                        .end_offset = @intCast(i),
                    });
                    field_idx += 1;
                    in_field = false;
                }
            }

            if (in_field) {
                try fields.append(allocator, .{
                    .line_idx = @intCast(idx),
                    .field_idx = field_idx,
                    .start_offset = field_start,
                    .end_offset = @intCast(line.len),
                });
                field_idx += 1;
            }

            // Update field_count for NF variable support
            match.field_count = field_idx - 1;
        }

        return AwkResult{
            .matches = matches,
            .fields = try fields.toOwnedSlice(allocator),
            .total_matches = match_count,
            .total_lines = @intCast(num_lines),
            .allocator = allocator,
        };
    }

    /// GPU-accelerated regex pattern matching
    pub fn processAwkRegex(self: *Self, text: []const u8, pattern: []const u8, options: AwkOptions, allocator: std.mem.Allocator) !AwkResult {
        if (text.len > MAX_GPU_BUFFER_SIZE) return error.TextTooLarge;

        // Compile regex pattern for GPU
        var gpu_regex = try regex_compiler.compileForGpu(pattern, .{
            .case_insensitive = options.case_insensitive,
        }, allocator);
        defer gpu_regex.deinit();

        // Find line boundaries
        var line_offsets: std.ArrayListUnmanaged(u32) = .{};
        defer line_offsets.deinit(allocator);
        var line_lengths: std.ArrayListUnmanaged(u32) = .{};
        defer line_lengths.deinit(allocator);

        var line_start: usize = 0;
        for (text, 0..) |c, i| {
            if (c == '\n') {
                try line_offsets.append(allocator, @intCast(line_start));
                try line_lengths.append(allocator, @intCast(i - line_start));
                line_start = i + 1;
            }
        }
        if (line_start < text.len) {
            try line_offsets.append(allocator, @intCast(line_start));
            try line_lengths.append(allocator, @intCast(text.len - line_start));
        }

        const num_lines = line_offsets.items.len;
        if (num_lines == 0) {
            return AwkResult{
                .matches = &[_]AwkMatchResult{},
                .fields = &[_]FieldInfo{},
                .total_matches = 0,
                .total_lines = 0,
                .allocator = allocator,
            };
        }

        // Create text buffer
        var text_buffer = self.device.newBufferWithLengthOptions(text.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer text_buffer.release();
        if (text_buffer.contents()) |ptr| {
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..text.len], text);
        }

        // Create states buffer
        const states_size = gpu_regex.states.len * @sizeOf(RegexState);
        var states_buffer = self.device.newBufferWithLengthOptions(@max(states_size, 1), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer states_buffer.release();
        if (states_size > 0) {
            if (states_buffer.contents()) |ptr| {
                const dst: [*]RegexState = @ptrCast(@alignCast(ptr));
                @memcpy(dst[0..gpu_regex.states.len], gpu_regex.states);
            }
        }

        // Create bitmaps buffer
        const bitmaps_size = gpu_regex.bitmaps.len * @sizeOf(u32);
        var bitmaps_buffer = self.device.newBufferWithLengthOptions(@max(bitmaps_size, 4), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer bitmaps_buffer.release();
        if (bitmaps_size > 0) {
            if (bitmaps_buffer.contents()) |ptr| {
                const dst: [*]u32 = @ptrCast(@alignCast(ptr));
                @memcpy(dst[0..gpu_regex.bitmaps.len], gpu_regex.bitmaps);
            }
        }

        // Create config buffer
        const config = AwkRegexConfig{
            .text_len = @intCast(text.len),
            .num_states = gpu_regex.header.num_states,
            .start_state = gpu_regex.header.start_state,
            .header_flags = gpu_regex.header.flags,
            .num_bitmaps = @intCast(gpu_regex.bitmaps.len / 8),
            .max_results = MAX_RESULTS,
            .flags = options.toFlags(),
        };
        var config_buffer = self.device.newBufferWithLengthOptions(@sizeOf(AwkRegexConfig), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer config_buffer.release();
        if (config_buffer.contents()) |ptr| {
            @as(*AwkRegexConfig, @ptrCast(@alignCast(ptr))).* = config;
        }

        // Create header buffer (for constant address space access)
        var header_buffer = self.device.newBufferWithLengthOptions(@sizeOf(mod.RegexHeader), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer header_buffer.release();
        if (header_buffer.contents()) |ptr| {
            @as(*mod.RegexHeader, @ptrCast(@alignCast(ptr))).* = gpu_regex.header;
        }

        // Create results buffer
        const results_size = @sizeOf(AwkMatchResult) * MAX_RESULTS;
        var results_buffer = self.device.newBufferWithLengthOptions(results_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer results_buffer.release();

        // Create counters buffer
        var counters_buffer = self.device.newBufferWithLengthOptions(4, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer counters_buffer.release();
        const counters_ptr: *u32 = @ptrCast(@alignCast(counters_buffer.contents()));
        counters_ptr.* = 0;

        // Create line offsets/lengths buffers
        var line_offsets_buffer = self.device.newBufferWithLengthOptions(line_offsets.items.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer line_offsets_buffer.release();
        if (line_offsets_buffer.contents()) |ptr| {
            @memcpy(@as([*]u32, @ptrCast(@alignCast(ptr)))[0..line_offsets.items.len], line_offsets.items);
        }

        var line_lengths_buffer = self.device.newBufferWithLengthOptions(line_lengths.items.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer line_lengths_buffer.release();
        if (line_lengths_buffer.contents()) |ptr| {
            @memcpy(@as([*]u32, @ptrCast(@alignCast(ptr)))[0..line_lengths.items.len], line_lengths.items);
        }

        // Execute regex matching
        var cmd_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = cmd_buffer.computeCommandEncoder() orelse return error.EncoderFailed;

        encoder.setComputePipelineState(self.regex_match_pipeline);
        encoder.setBufferOffsetAtIndex(text_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(states_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(bitmaps_buffer, 0, 2);
        encoder.setBufferOffsetAtIndex(config_buffer, 0, 3);
        encoder.setBufferOffsetAtIndex(header_buffer, 0, 4);
        encoder.setBufferOffsetAtIndex(results_buffer, 0, 5);
        encoder.setBufferOffsetAtIndex(counters_buffer, 0, 6);
        encoder.setBufferOffsetAtIndex(line_offsets_buffer, 0, 7);
        encoder.setBufferOffsetAtIndex(line_lengths_buffer, 0, 8);

        const grid_size = mtl.MTLSize{ .width = num_lines, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = @min(self.threads_per_group, num_lines), .height = 1, .depth = 1 };

        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);
        encoder.endEncoding();
        cmd_buffer.commit();
        cmd_buffer.waitUntilCompleted();

        const match_count = counters_ptr.*;

        // Copy results
        const num_to_copy = @min(match_count, MAX_RESULTS);
        const matches = try allocator.alloc(AwkMatchResult, num_to_copy);
        if (num_to_copy > 0) {
            const results_ptr: [*]AwkMatchResult = @ptrCast(@alignCast(results_buffer.contents()));
            @memcpy(matches, results_ptr[0..num_to_copy]);
        }

        // Do field splitting on CPU
        var fields: std.ArrayListUnmanaged(FieldInfo) = .{};
        for (matches, 0..) |*match, idx| {
            const line = text[match.line_start..match.line_end];
            var field_idx: u32 = 1;
            var field_start_pos: u32 = 0;
            var in_field = false;

            for (line, 0..) |c, i| {
                var is_sep = false;
                for (options.field_separator) |s| {
                    if (c == s) {
                        is_sep = true;
                        break;
                    }
                }

                if (!is_sep and !in_field) {
                    in_field = true;
                    field_start_pos = @intCast(i);
                } else if (is_sep and in_field) {
                    try fields.append(allocator, .{
                        .line_idx = @intCast(idx),
                        .field_idx = field_idx,
                        .start_offset = field_start_pos,
                        .end_offset = @intCast(i),
                    });
                    field_idx += 1;
                    in_field = false;
                }
            }

            if (in_field) {
                try fields.append(allocator, .{
                    .line_idx = @intCast(idx),
                    .field_idx = field_idx,
                    .start_offset = field_start_pos,
                    .end_offset = @intCast(line.len),
                });
                field_idx += 1;
            }

            match.field_count = field_idx - 1;
        }

        return AwkResult{
            .matches = matches,
            .fields = try fields.toOwnedSlice(allocator),
            .total_matches = match_count,
            .total_lines = @intCast(num_lines),
            .allocator = allocator,
        };
    }
};
