const std = @import("std");
const mod = @import("mod.zig");
const regex_lib = @import("regex");

const RegexState = mod.RegexState;
const RegexHeader = mod.RegexHeader;
const RegexStateType = mod.RegexStateType;
const MAX_REGEX_STATES = mod.MAX_REGEX_STATES;
const BITMAP_WORDS_PER_CLASS = mod.BITMAP_WORDS_PER_CLASS;

pub const CompiledGpuRegex = struct {
    header: RegexHeader,
    states: []RegexState,
    bitmaps: []u32, // Flattened bitmap data (8 words per character class)
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompiledGpuRegex) void {
        self.allocator.free(self.states);
        self.allocator.free(self.bitmaps);
    }
};

/// Convert CPU regex to GPU-compatible format
pub fn compileForGpu(pattern: []const u8, options: regex_lib.Regex.Options, allocator: std.mem.Allocator) !CompiledGpuRegex {
    // Compile the regex on CPU first
    var cpu_regex = regex_lib.Regex.compile(allocator, pattern, options) catch |err| {
        return err;
    };
    defer cpu_regex.deinit();

    return convertToGpuFormat(&cpu_regex, allocator);
}

/// Convert an already-compiled CPU regex to GPU format
pub fn convertToGpuFormat(cpu_regex: *regex_lib.Regex, allocator: std.mem.Allocator) !CompiledGpuRegex {
    const states = cpu_regex.states;

    if (states.len > MAX_REGEX_STATES) {
        return error.TooManyStates;
    }

    // First pass: count character classes for bitmap allocation
    var num_char_classes: u32 = 0;
    for (states) |state| {
        if (state.type == .char_class) {
            num_char_classes += 1;
        }
    }

    // Allocate GPU state array
    const gpu_states = try allocator.alloc(RegexState, states.len);
    errdefer allocator.free(gpu_states);

    // Allocate bitmap buffer (8 u32 words per character class)
    const bitmap_words = num_char_classes * BITMAP_WORDS_PER_CLASS;
    const bitmaps: []u32 = if (bitmap_words > 0)
        try allocator.alloc(u32, bitmap_words)
    else
        @constCast(&[_]u32{});
    errdefer if (bitmap_words > 0) allocator.free(bitmaps);

    // Convert states and copy bitmaps
    var bitmap_offset: u32 = 0;
    for (states, 0..) |state, i| {
        gpu_states[i] = convertState(state, &bitmap_offset, bitmaps);
    }

    // Build header
    const header = RegexHeader{
        .num_states = @intCast(states.len),
        .start_state = cpu_regex.start_state,
        .num_groups = @intCast(cpu_regex.num_groups),
        .flags = buildHeaderFlags(cpu_regex),
    };

    return CompiledGpuRegex{
        .header = header,
        .states = gpu_states,
        .bitmaps = bitmaps,
        .allocator = allocator,
    };
}

fn convertState(state: regex_lib.State, bitmap_offset: *u32, bitmaps: []u32) RegexState {
    var gpu_state = RegexState{
        .type = @intFromEnum(state.type),
        .flags = 0,
        .out = if (state.out == regex_lib.State.NONE) 0xFFFF else @intCast(@min(state.out, 0xFFFF)),
        .out2 = if (state.out2 == regex_lib.State.NONE) 0xFFFF else @intCast(@min(state.out2, 0xFFFF)),
        .literal_char = 0,
        .group_idx = 0,
        .bitmap_offset = 0,
    };

    switch (state.type) {
        .literal => {
            gpu_state.literal_char = state.data.literal.char;
            if (state.data.literal.case_insensitive) {
                gpu_state.flags |= RegexState.FLAG_CASE_INSENSITIVE;
            }
        },
        .char_class => {
            // Copy 32-byte bitmap to GPU format (8 x u32)
            const cpu_bitmap = state.data.char_class.bitmap;
            const offset = bitmap_offset.*;

            // Convert 32-byte bitmap to 8 x u32
            var j: usize = 0;
            while (j < 8) : (j += 1) {
                const byte_idx = j * 4;
                bitmaps[offset + j] =
                    @as(u32, cpu_bitmap.bitmap[byte_idx]) |
                    (@as(u32, cpu_bitmap.bitmap[byte_idx + 1]) << 8) |
                    (@as(u32, cpu_bitmap.bitmap[byte_idx + 2]) << 16) |
                    (@as(u32, cpu_bitmap.bitmap[byte_idx + 3]) << 24);
            }

            gpu_state.bitmap_offset = offset;
            if (state.data.char_class.negated) {
                gpu_state.flags |= RegexState.FLAG_NEGATED;
            }
            bitmap_offset.* += BITMAP_WORDS_PER_CLASS;
        },
        .group_start, .group_end => {
            gpu_state.group_idx = @intCast(state.data.group_idx);
        },
        else => {},
    }

    return gpu_state;
}

fn buildHeaderFlags(cpu_regex: *regex_lib.Regex) u32 {
    var flags: u32 = 0;
    if (cpu_regex.anchored_start) flags |= RegexHeader.FLAG_ANCHORED_START;
    if (cpu_regex.anchored_end) flags |= RegexHeader.FLAG_ANCHORED_END;
    if (cpu_regex.case_insensitive) flags |= RegexHeader.FLAG_CASE_INSENSITIVE;
    return flags;
}

// Tests
test "compile simple literal pattern for GPU" {
    const allocator = std.testing.allocator;
    var compiled = try compileForGpu("hello", .{}, allocator);
    defer compiled.deinit();

    try std.testing.expect(compiled.header.num_states > 0);
    try std.testing.expectEqual(@as(u32, 0), compiled.header.start_state);
}

test "compile character class pattern for GPU" {
    const allocator = std.testing.allocator;
    var compiled = try compileForGpu("[a-z]+", .{}, allocator);
    defer compiled.deinit();

    try std.testing.expect(compiled.header.num_states > 0);
    try std.testing.expect(compiled.bitmaps.len > 0);
}

test "compile anchored pattern for GPU" {
    const allocator = std.testing.allocator;
    var compiled = try compileForGpu("^hello$", .{}, allocator);
    defer compiled.deinit();

    try std.testing.expectEqual(RegexHeader.FLAG_ANCHORED_START | RegexHeader.FLAG_ANCHORED_END, compiled.header.flags);
}
