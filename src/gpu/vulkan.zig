const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const spirv = @import("spirv");
const mod = @import("mod.zig");

const AwkConfig = mod.AwkConfig;
const AwkMatchResult = mod.AwkMatchResult;
const FieldInfo = mod.FieldInfo;
const AwkOptions = mod.AwkOptions;
const AwkResult = mod.AwkResult;
const MAX_RESULTS = mod.MAX_RESULTS;
const MAX_FIELDS = mod.MAX_FIELDS;
const MAX_GPU_BUFFER_SIZE = mod.MAX_GPU_BUFFER_SIZE;

const VulkanLoader = struct {
    lib: std.DynLib,
    getProcAddr: vk.PfnGetInstanceProcAddr,

    fn load() !VulkanLoader {
        const lib_names = switch (builtin.os.tag) {
            .macos => &[_][]const u8{ "libMoltenVK.dylib", "libvulkan.1.dylib", "libvulkan.dylib" },
            .linux => &[_][]const u8{ "libvulkan.so.1", "libvulkan.so" },
            .windows => &[_][]const u8{"vulkan-1.dll"},
            else => return error.UnsupportedPlatform,
        };

        for (lib_names) |name| {
            var lib = std.DynLib.open(name) catch continue;
            if (lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr")) |proc| {
                return .{ .lib = lib, .getProcAddr = proc };
            }
            lib.close();
        }
        return error.VulkanNotFound;
    }
};

var vulkan_loader: ?VulkanLoader = null;

fn getVkGetInstanceProcAddr() !vk.PfnGetInstanceProcAddr {
    if (vulkan_loader) |loader| return loader.getProcAddr;
    vulkan_loader = try VulkanLoader.load();
    return vulkan_loader.?.getProcAddr;
}

pub const VulkanAwk = struct {
    instance: vk.Instance,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    compute_queue: vk.Queue,
    compute_queue_family: u32,
    descriptor_set_layout: vk.DescriptorSetLayout,
    pipeline_layout: vk.PipelineLayout,
    compute_pipeline: vk.Pipeline,
    descriptor_pool: vk.DescriptorPool,
    shader_module: vk.ShaderModule,
    command_pool: vk.CommandPool,
    fence: vk.Fence,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    allocator: std.mem.Allocator,
    vkb: vk.BaseWrapper,
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    capabilities: mod.GpuCapabilities,

    const Self = @This();
    const BufferAllocation = struct { buffer: vk.Buffer, memory: vk.DeviceMemory, size: vk.DeviceSize, mapped: ?*anyopaque };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const vkb = vk.BaseWrapper.load(try getVkGetInstanceProcAddr());

        const app_info = vk.ApplicationInfo{
            .p_application_name = "gawk",
            .application_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .p_engine_name = "gawk",
            .engine_version = @bitCast(vk.makeApiVersion(0, 1, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_2),
        };

        const instance = vkb.createInstance(&.{ .p_application_info = &app_info, .enabled_layer_count = 0, .pp_enabled_layer_names = null, .enabled_extension_count = 0, .pp_enabled_extension_names = null }, null) catch return error.InstanceCreationFailed;
        const vki = vk.InstanceWrapper.load(instance, vkb.dispatch.vkGetInstanceProcAddr.?);
        errdefer vki.destroyInstance(instance, null);

        var device_count: u32 = 0;
        _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);
        if (device_count == 0) return error.NoVulkanDevice;

        var physical_devices: [16]vk.PhysicalDevice = undefined;
        device_count = @min(device_count, 16);
        _ = try vki.enumeratePhysicalDevices(instance, &device_count, &physical_devices);

        var selected_device: ?vk.PhysicalDevice = null;
        var selected_queue_family: u32 = 0;
        var selected_props: vk.PhysicalDeviceProperties = undefined;

        for (physical_devices[0..device_count]) |pdev| {
            const props = vki.getPhysicalDeviceProperties(pdev);

            var queue_count: u32 = 0;
            vki.getPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, null);
            var queue_props: [32]vk.QueueFamilyProperties = undefined;
            queue_count = @min(queue_count, 32);
            vki.getPhysicalDeviceQueueFamilyProperties(pdev, &queue_count, &queue_props);

            for (queue_props[0..queue_count], 0..) |qp, i| {
                if (qp.queue_flags.compute_bit) {
                    if (selected_device == null or
                        (props.device_type == .discrete_gpu and selected_props.device_type != .discrete_gpu))
                    {
                        selected_device = pdev;
                        selected_queue_family = @intCast(i);
                        selected_props = props;
                    }
                    break;
                }
            }
        }

        const physical_device = selected_device orelse return error.NoComputeQueue;

        const queue_priority: f32 = 1.0;
        const device = vki.createDevice(physical_device, &.{
            .queue_create_info_count = 1,
            .p_queue_create_infos = @ptrCast(&vk.DeviceQueueCreateInfo{ .queue_family_index = selected_queue_family, .queue_count = 1, .p_queue_priorities = @ptrCast(&queue_priority) }),
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
            .enabled_extension_count = 0,
            .pp_enabled_extension_names = null,
            .p_enabled_features = null,
        }, null) catch return error.DeviceCreationFailed;

        const vkd = vk.DeviceWrapper.load(device, vki.dispatch.vkGetDeviceProcAddr.?);
        errdefer vkd.destroyDevice(device, null);

        const compute_queue = vkd.getDeviceQueue(device, selected_queue_family, 0);

        const shader_module = vkd.createShaderModule(device, &.{ .code_size = spirv.EMBEDDED_SPIRV.len, .p_code = @ptrCast(@alignCast(spirv.EMBEDDED_SPIRV.ptr)) }, null) catch return error.ShaderModuleCreationFailed;
        errdefer vkd.destroyShaderModule(device, shader_module, null);

        const bindings = [_]vk.DescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 1, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 2, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 3, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 4, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 5, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 6, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
            .{ .binding = 7, .descriptor_type = .storage_buffer, .descriptor_count = 1, .stage_flags = .{ .compute_bit = true }, .p_immutable_samplers = null },
        };

        const descriptor_set_layout = vkd.createDescriptorSetLayout(device, &.{ .binding_count = bindings.len, .p_bindings = &bindings }, null) catch return error.DescriptorSetLayoutCreationFailed;
        errdefer vkd.destroyDescriptorSetLayout(device, descriptor_set_layout, null);

        const pipeline_layout = vkd.createPipelineLayout(device, &.{ .set_layout_count = 1, .p_set_layouts = @ptrCast(&descriptor_set_layout), .push_constant_range_count = 0, .p_push_constant_ranges = null }, null) catch return error.PipelineLayoutCreationFailed;
        errdefer vkd.destroyPipelineLayout(device, pipeline_layout, null);

        var compute_pipeline: vk.Pipeline = undefined;
        _ = vkd.createComputePipelines(device, .null_handle, 1, @ptrCast(&vk.ComputePipelineCreateInfo{
            .stage = .{ .stage = .{ .compute_bit = true }, .module = shader_module, .p_name = "main", .p_specialization_info = null },
            .layout = pipeline_layout,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        }), null, @ptrCast(&compute_pipeline)) catch return error.ComputePipelineCreationFailed;
        errdefer vkd.destroyPipeline(device, compute_pipeline, null);

        const descriptor_pool = vkd.createDescriptorPool(device, &.{ .max_sets = 1, .pool_size_count = 1, .p_pool_sizes = @ptrCast(&vk.DescriptorPoolSize{ .type = .storage_buffer, .descriptor_count = 8 }) }, null) catch return error.DescriptorPoolCreationFailed;
        errdefer vkd.destroyDescriptorPool(device, descriptor_pool, null);

        const command_pool = vkd.createCommandPool(device, &.{ .queue_family_index = selected_queue_family, .flags = .{ .reset_command_buffer_bit = true } }, null) catch return error.CommandPoolCreationFailed;
        errdefer vkd.destroyCommandPool(device, command_pool, null);

        const fence = vkd.createFence(device, &.{ .flags = .{} }, null) catch return error.FenceCreationFailed;
        errdefer vkd.destroyFence(device, fence, null);

        const mem_props = vki.getPhysicalDeviceMemoryProperties(physical_device);

        const is_discrete = selected_props.device_type == .discrete_gpu;
        const device_type: mod.GpuCapabilities.DeviceType = switch (selected_props.device_type) {
            .discrete_gpu => .discrete,
            .integrated_gpu => .integrated,
            .virtual_gpu => .virtual,
            .cpu => .cpu,
            else => .other,
        };

        const max_threads = selected_props.limits.max_compute_work_group_invocations;
        const max_buffer = selected_props.limits.max_storage_buffer_range;

        var device_local_memory: u64 = 0;
        for (0..mem_props.memory_heap_count) |i| {
            const heap = mem_props.memory_heaps[i];
            if (heap.flags.device_local_bit) {
                device_local_memory += heap.size;
            }
        }

        const capabilities = mod.GpuCapabilities{
            .max_threads_per_group = max_threads,
            .max_buffer_size = max_buffer,
            .recommended_memory = device_local_memory,
            .is_discrete = is_discrete,
            .device_type = device_type,
        };

        const self = try allocator.create(Self);
        self.* = Self{
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .compute_queue = compute_queue,
            .compute_queue_family = selected_queue_family,
            .descriptor_set_layout = descriptor_set_layout,
            .pipeline_layout = pipeline_layout,
            .compute_pipeline = compute_pipeline,
            .descriptor_pool = descriptor_pool,
            .shader_module = shader_module,
            .command_pool = command_pool,
            .fence = fence,
            .mem_props = mem_props,
            .allocator = allocator,
            .vkb = vkb,
            .vki = vki,
            .vkd = vkd,
            .capabilities = capabilities,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.vkd.destroyFence(self.device, self.fence, null);
        self.vkd.destroyCommandPool(self.device, self.command_pool, null);
        self.vkd.destroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.vkd.destroyPipeline(self.device, self.compute_pipeline, null);
        self.vkd.destroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.vkd.destroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
        self.vkd.destroyShaderModule(self.device, self.shader_module, null);
        self.vkd.destroyDevice(self.device, null);
        self.vki.destroyInstance(self.instance, null);
        self.allocator.destroy(self);
    }

    fn createBuffer(self: *Self, size: vk.DeviceSize) !BufferAllocation {
        const buffer = self.vkd.createBuffer(self.device, &.{ .size = size, .usage = .{ .storage_buffer_bit = true }, .sharing_mode = .exclusive, .queue_family_index_count = 0, .p_queue_family_indices = null }, null) catch return error.BufferCreationFailed;
        const mem_reqs = self.vkd.getBufferMemoryRequirements(self.device, buffer);
        const mem_type_index = findMemoryType(&self.mem_props, mem_reqs.memory_type_bits, .{ .host_visible_bit = true, .host_coherent_bit = true }) orelse return error.NoSuitableMemoryType;
        const memory = self.vkd.allocateMemory(self.device, &.{ .allocation_size = mem_reqs.size, .memory_type_index = mem_type_index }, null) catch return error.MemoryAllocationFailed;
        self.vkd.bindBufferMemory(self.device, buffer, memory, 0) catch return error.MemoryBindFailed;
        const mapped = self.vkd.mapMemory(self.device, memory, 0, size, .{}) catch return error.MemoryMapFailed;
        return BufferAllocation{ .buffer = buffer, .memory = memory, .size = size, .mapped = mapped };
    }

    fn destroyBuffer(self: *Self, buf: BufferAllocation) void {
        self.vkd.unmapMemory(self.device, buf.memory);
        self.vkd.freeMemory(self.device, buf.memory, null);
        self.vkd.destroyBuffer(self.device, buf.buffer, null);
    }

    pub fn processAwk(self: *Self, text: []const u8, pattern: []const u8, options: AwkOptions, allocator: std.mem.Allocator) !AwkResult {
        if (text.len > MAX_GPU_BUFFER_SIZE) return error.TextTooLarge;

        // Find line boundaries on CPU
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

        // Create buffers
        const text_size: vk.DeviceSize = @intCast(((text.len + 3) / 4) * 4);
        const text_buffer = try self.createBuffer(text_size);
        defer self.destroyBuffer(text_buffer);
        @memcpy(@as([*]u8, @ptrCast(text_buffer.mapped))[0..text.len], text);

        const pattern_len = if (pattern.len > 0) pattern.len else 1;
        const pattern_size: vk.DeviceSize = @intCast(((pattern_len + 3) / 4) * 4);
        const pattern_buffer = try self.createBuffer(pattern_size);
        defer self.destroyBuffer(pattern_buffer);
        if (pattern.len > 0) {
            @memcpy(@as([*]u8, @ptrCast(pattern_buffer.mapped))[0..pattern.len], pattern);
        }

        const skip_buffer = try self.createBuffer(256);
        defer self.destroyBuffer(skip_buffer);
        const skip_table = if (pattern.len > 0) mod.buildSkipTable(pattern, options.case_insensitive) else [_]u8{1} ** 256;
        @as(*[256]u8, @ptrCast(@alignCast(skip_buffer.mapped))).* = skip_table;

        const config_buffer = try self.createBuffer(@sizeOf(AwkConfig));
        defer self.destroyBuffer(config_buffer);
        @as(*AwkConfig, @ptrCast(@alignCast(config_buffer.mapped))).* = AwkConfig{
            .text_len = @intCast(text.len),
            .pattern_len = @intCast(pattern.len),
            .field_sep_len = @intCast(options.field_separator.len),
            .num_fields_requested = @intCast(options.requested_fields.len),
            .flags = options.toFlags(),
            .max_results = MAX_RESULTS,
            .max_fields = MAX_FIELDS,
            .replacement_len = 0,
        };

        const results_size: vk.DeviceSize = @intCast(@sizeOf(AwkMatchResult) * MAX_RESULTS);
        const results_buffer = try self.createBuffer(results_size);
        defer self.destroyBuffer(results_buffer);

        const counters_buffer = try self.createBuffer(8);
        defer self.destroyBuffer(counters_buffer);
        const counters_ptr: *[2]u32 = @ptrCast(@alignCast(counters_buffer.mapped));
        counters_ptr[0] = 0;
        counters_ptr[1] = 0;

        const line_offsets_size: vk.DeviceSize = @intCast(line_offsets.items.len * @sizeOf(u32));
        const line_offsets_buffer = try self.createBuffer(line_offsets_size);
        defer self.destroyBuffer(line_offsets_buffer);
        @memcpy(@as([*]u32, @ptrCast(@alignCast(line_offsets_buffer.mapped)))[0..line_offsets.items.len], line_offsets.items);

        const line_lengths_size: vk.DeviceSize = @intCast(line_lengths.items.len * @sizeOf(u32));
        const line_lengths_buffer = try self.createBuffer(line_lengths_size);
        defer self.destroyBuffer(line_lengths_buffer);
        @memcpy(@as([*]u32, @ptrCast(@alignCast(line_lengths_buffer.mapped)))[0..line_lengths.items.len], line_lengths.items);

        // Set up descriptor set
        var descriptor_set: vk.DescriptorSet = undefined;
        self.vkd.allocateDescriptorSets(self.device, &.{ .descriptor_pool = self.descriptor_pool, .descriptor_set_count = 1, .p_set_layouts = @ptrCast(&self.descriptor_set_layout) }, @ptrCast(&descriptor_set)) catch return error.DescriptorSetAllocationFailed;

        const buffer_infos = [_]vk.DescriptorBufferInfo{
            .{ .buffer = text_buffer.buffer, .offset = 0, .range = text_size },
            .{ .buffer = pattern_buffer.buffer, .offset = 0, .range = pattern_size },
            .{ .buffer = skip_buffer.buffer, .offset = 0, .range = 256 },
            .{ .buffer = config_buffer.buffer, .offset = 0, .range = @sizeOf(AwkConfig) },
            .{ .buffer = results_buffer.buffer, .offset = 0, .range = results_size },
            .{ .buffer = counters_buffer.buffer, .offset = 0, .range = 8 },
            .{ .buffer = line_offsets_buffer.buffer, .offset = 0, .range = line_offsets_size },
            .{ .buffer = line_lengths_buffer.buffer, .offset = 0, .range = line_lengths_size },
        };

        var writes: [8]vk.WriteDescriptorSet = undefined;
        for (0..8) |i| {
            writes[i] = .{
                .dst_set = descriptor_set,
                .dst_binding = @intCast(i),
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_image_info = undefined,
                .p_buffer_info = @ptrCast(&buffer_infos[i]),
                .p_texel_buffer_view = undefined,
            };
        }
        self.vkd.updateDescriptorSets(self.device, 8, &writes, 0, undefined);

        // Execute
        var command_buffer: vk.CommandBuffer = undefined;
        self.vkd.allocateCommandBuffers(self.device, &.{ .command_pool = self.command_pool, .level = .primary, .command_buffer_count = 1 }, @ptrCast(&command_buffer)) catch return error.CommandBufferAllocationFailed;
        defer self.vkd.freeCommandBuffers(self.device, self.command_pool, 1, @ptrCast(&command_buffer));

        self.vkd.beginCommandBuffer(command_buffer, &.{ .flags = .{ .one_time_submit_bit = true } }) catch return error.CommandBufferBeginFailed;
        self.vkd.cmdBindPipeline(command_buffer, .compute, self.compute_pipeline);
        self.vkd.cmdBindDescriptorSets(command_buffer, .compute, self.pipeline_layout, 0, 1, @ptrCast(&descriptor_set), 0, undefined);

        const workgroups = @max(1, (num_lines + 63) / 64);
        self.vkd.cmdDispatch(command_buffer, @intCast(workgroups), 1, 1);
        self.vkd.endCommandBuffer(command_buffer) catch return error.CommandBufferEndFailed;

        self.vkd.queueSubmit(self.compute_queue, 1, @ptrCast(&vk.SubmitInfo{
            .wait_semaphore_count = 0,
            .p_wait_semaphores = undefined,
            .p_wait_dst_stage_mask = undefined,
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&command_buffer),
            .signal_semaphore_count = 0,
            .p_signal_semaphores = undefined,
        }), self.fence) catch return error.QueueSubmitFailed;
        _ = self.vkd.waitForFences(self.device, 1, @ptrCast(&self.fence), .true, std.math.maxInt(u64)) catch return error.FenceWaitFailed;
        self.vkd.resetFences(self.device, 1, @ptrCast(&self.fence)) catch return error.FenceResetFailed;

        const match_count = counters_ptr[0];

        const num_to_copy = @min(match_count, MAX_RESULTS);
        const matches = try allocator.alloc(AwkMatchResult, num_to_copy);
        if (num_to_copy > 0) @memcpy(matches, @as([*]AwkMatchResult, @ptrCast(@alignCast(results_buffer.mapped)))[0..num_to_copy]);

        self.vkd.resetDescriptorPool(self.device, self.descriptor_pool, .{}) catch {};

        // Field splitting on CPU
        var fields: std.ArrayListUnmanaged(FieldInfo) = .{};
        for (matches, 0..) |match, idx| {
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
            }
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

fn findMemoryType(mem_props: *const vk.PhysicalDeviceMemoryProperties, type_filter: u32, properties: vk.MemoryPropertyFlags) ?u32 {
    for (0..mem_props.memory_type_count) |i| {
        const idx: u5 = @intCast(i);
        if ((type_filter & (@as(u32, 1) << idx)) != 0) {
            const mem_type = mem_props.memory_types[i];
            if (mem_type.property_flags.host_visible_bit == properties.host_visible_bit and mem_type.property_flags.host_coherent_bit == properties.host_coherent_bit) return @intCast(i);
        }
    }
    return null;
}
