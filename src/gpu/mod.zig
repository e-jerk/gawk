const std = @import("std");
const build_options = @import("build_options");

// Import e_jerk_gpu library for GPU detection and auto-selection
pub const e_jerk_gpu = @import("e_jerk_gpu");

// Re-export library types for use across gawk
pub const GpuCapabilities = e_jerk_gpu.GpuCapabilities;
pub const AutoSelector = e_jerk_gpu.AutoSelector;
pub const AutoSelectConfig = e_jerk_gpu.AutoSelectConfig;
pub const WorkloadInfo = e_jerk_gpu.WorkloadInfo;
pub const SelectionResult = e_jerk_gpu.SelectionResult;

pub const metal = if (build_options.is_macos) @import("metal.zig") else struct {
    pub const MetalAwk = void;
};
pub const vulkan = @import("vulkan.zig");
pub const regex_compiler = @import("regex_compiler.zig");

// Configuration
pub const BATCH_SIZE: usize = 1024 * 1024;
pub const MAX_GPU_BUFFER_SIZE: usize = 64 * 1024 * 1024;
pub const MIN_GPU_SIZE: usize = 128 * 1024;
pub const MAX_PATTERN_LEN: u32 = 256;
pub const MAX_RESULTS: u32 = 1000000;
pub const MAX_FIELDS: u32 = 100000;
pub const MAX_FIELD_SEP_LEN: u32 = 16;

pub const EMBEDDED_METAL_SHADER = if (build_options.is_macos) @import("metal_shader").EMBEDDED_METAL_SHADER else "";

// AWK-specific data structures (GPU-aligned)
pub const AwkConfig = extern struct {
    text_len: u32,
    pattern_len: u32,
    field_sep_len: u32,
    num_fields_requested: u32,
    flags: u32,
    max_results: u32,
    max_fields: u32,
    replacement_len: u32,
};

pub const AwkFlags = struct {
    pub const CASE_INSENSITIVE: u32 = 1;
    pub const PRINT_LINE_NUMBER: u32 = 2;
    pub const FIELD_EXTRACTION: u32 = 4;
    pub const SUBSTITUTION_MODE: u32 = 8;
    pub const GLOBAL_SUBSTITUTION: u32 = 16;
    pub const INVERT_MATCH: u32 = 32;
    pub const REGEX_FIELD_SEP: u32 = 64;
};

pub const AwkMatchResult = extern struct {
    line_start: u32,
    line_end: u32,
    match_start: u32,
    match_end: u32,
    line_num: u32,
    field_count: u32,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

pub const FieldInfo = extern struct {
    line_idx: u32,
    field_idx: u32, // 1-indexed like AWK
    start_offset: u32,
    end_offset: u32,
};

pub const SubstitutionResult = extern struct {
    position: u32,
    match_len: u32,
    line_num: u32,
    _pad: u32 = 0,
};

// ============================================================================
// GPU Regex Types (match shader structs in regex_ops.h / regex_ops.glsl)
// ============================================================================

pub const MAX_REGEX_STATES: u32 = 256;
pub const MAX_CAPTURE_GROUPS: u32 = 16;
pub const BITMAP_WORDS_PER_CLASS: u32 = 8; // 256 bits = 8 x 32-bit words

/// NFA state types - must match shader enums
pub const RegexStateType = enum(u8) {
    literal = 0, // Match single character
    char_class = 1, // Match character class using bitmap
    dot = 2, // Match any character except newline
    split = 3, // Epsilon split to two states
    match = 4, // Accept state
    group_start = 5, // Capture group start
    group_end = 6, // Capture group end
    word_boundary = 7, // \b
    not_word_boundary = 8, // \B
    line_start = 9, // ^
    line_end = 10, // $
    any = 11, // . including newline
};

/// Compiled regex state (GPU-aligned, matches shader struct)
pub const RegexState = extern struct {
    type: u8, // RegexStateType
    flags: u8, // case_insensitive, negated, etc.
    out: u16, // Next state index
    out2: u16, // Second output for split states
    literal_char: u8, // For literal states
    group_idx: u8, // For group_start/end
    bitmap_offset: u32, // Offset into bitmap buffer for char_class

    pub const FLAG_CASE_INSENSITIVE: u8 = 0x01;
    pub const FLAG_NEGATED: u8 = 0x02;
};

/// Compiled regex header (uploaded with pattern)
pub const RegexHeader = extern struct {
    num_states: u32,
    start_state: u32,
    num_groups: u32,
    flags: u32,

    pub const FLAG_ANCHORED_START: u32 = 0x01;
    pub const FLAG_ANCHORED_END: u32 = 0x02;
    pub const FLAG_CASE_INSENSITIVE: u32 = 0x04;
};

/// GPU regex match result
pub const RegexMatchResult = extern struct {
    start: u32,
    end: u32,
    pattern_idx: u32,
    flags: u32, // valid, etc.

    pub const FLAG_VALID: u32 = 0x01;
};

/// AWK config extended for regex operations
pub const AwkRegexConfig = extern struct {
    text_len: u32,
    num_states: u32,
    start_state: u32,
    header_flags: u32,
    num_bitmaps: u32,
    max_results: u32,
    flags: u32, // Standard AwkFlags
    _pad: u32 = 0,
};

pub const AwkOptions = struct {
    case_insensitive: bool = false,
    print_line_number: bool = false,
    invert_match: bool = false,
    field_separator: []const u8 = " \t",
    output_field_separator: []const u8 = " ",
    requested_fields: []const u32 = &.{},
    global_substitution: bool = true,

    pub fn toFlags(self: AwkOptions) u32 {
        var flags: u32 = 0;
        if (self.case_insensitive) flags |= AwkFlags.CASE_INSENSITIVE;
        if (self.print_line_number) flags |= AwkFlags.PRINT_LINE_NUMBER;
        if (self.requested_fields.len > 0) flags |= AwkFlags.FIELD_EXTRACTION;
        if (self.invert_match) flags |= AwkFlags.INVERT_MATCH;
        if (self.global_substitution) flags |= AwkFlags.GLOBAL_SUBSTITUTION;
        return flags;
    }
};

pub const AwkResult = struct {
    matches: []AwkMatchResult,
    fields: []FieldInfo,
    total_matches: u64,
    total_lines: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AwkResult) void {
        self.allocator.free(self.matches);
        self.allocator.free(self.fields);
    }
};

pub fn buildSkipTable(pattern: []const u8, case_insensitive: bool) [256]u8 {
    var skip_table: [256]u8 = undefined;
    const default_skip: u8 = @intCast(@min(pattern.len, 255));
    @memset(&skip_table, default_skip);

    if (pattern.len > 1) {
        for (pattern[0 .. pattern.len - 1], 0..) |c, i| {
            const skip: u8 = @intCast(pattern.len - 1 - i);
            skip_table[c] = skip;
            if (case_insensitive) {
                if (c >= 'A' and c <= 'Z') skip_table[c + 32] = skip;
                if (c >= 'a' and c <= 'z') skip_table[c - 32] = skip;
            }
        }
    }
    return skip_table;
}

// Use library's Backend enum
pub const Backend = e_jerk_gpu.Backend;

pub fn detectBestBackend() Backend {
    if (build_options.is_macos) return .metal;
    return .vulkan;
}

pub fn shouldUseGpu(text_len: usize) bool {
    return text_len >= MIN_GPU_SIZE;
}

pub fn formatBytes(bytes: usize) struct { value: f64, unit: []const u8 } {
    if (bytes >= 1024 * 1024 * 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024), .unit = "GB" };
    if (bytes >= 1024 * 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / (1024 * 1024), .unit = "MB" };
    if (bytes >= 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / 1024, .unit = "KB" };
    return .{ .value = @as(f64, @floatFromInt(bytes)), .unit = "B" };
}
