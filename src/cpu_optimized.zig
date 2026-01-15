const std = @import("std");
const gpu = @import("gpu");
const regex_lib = @import("regex");

const AwkConfig = gpu.AwkConfig;
const AwkMatchResult = gpu.AwkMatchResult;
const FieldInfo = gpu.FieldInfo;
const AwkOptions = gpu.AwkOptions;
const AwkResult = gpu.AwkResult;
const SubstitutionResult = gpu.SubstitutionResult;

// Re-export for use by other modules
pub const Regex = regex_lib.Regex;
pub const isRegexPattern = regex_lib.isRegexPattern;

// SIMD vector types for optimal performance
const Vec16 = @Vector(16, u8);
const Vec32 = @Vector(32, u8);

// Constants for vectorized operations
const NEWLINE_VEC32: Vec32 = @splat('\n');
const SPACE_VEC32: Vec32 = @splat(' ');
const TAB_VEC32: Vec32 = @splat('\t');
const UPPER_A_VEC16: Vec16 = @splat('A');
const UPPER_Z_VEC16: Vec16 = @splat('Z');
const CASE_DIFF_VEC16: Vec16 = @splat(32);

/// CPU-based AWK pattern matching and field extraction with SIMD optimization
pub fn processAwk(
    text: []const u8,
    pattern: []const u8,
    options: AwkOptions,
    allocator: std.mem.Allocator,
) !AwkResult {
    var matches: std.ArrayListUnmanaged(AwkMatchResult) = .{};
    errdefer matches.deinit(allocator);
    var fields: std.ArrayListUnmanaged(FieldInfo) = .{};
    errdefer fields.deinit(allocator);

    // Pre-compute lowercase pattern if case insensitive
    var lower_pattern_buf: [1024]u8 = undefined;
    const search_pattern = if (options.case_insensitive and pattern.len > 0 and pattern.len <= 1024) blk: {
        toLowerSlice(pattern, lower_pattern_buf[0..pattern.len]);
        break :blk lower_pattern_buf[0..pattern.len];
    } else pattern;

    const skip_table = if (pattern.len > 0) gpu.buildSkipTable(search_pattern, options.case_insensitive) else [_]u8{1} ** 256;

    var line_start: usize = 0;
    var line_num: u32 = 0;

    while (line_start < text.len) {
        // Find line end using SIMD
        const line_end = findNextNewlineSIMD(text, line_start);
        const line = text[line_start..line_end];

        var found_match = false;
        var match_pos: usize = 0;

        // Pattern matching
        if (pattern.len == 0) {
            found_match = true;
        } else if (line.len >= pattern.len) {
            found_match = searchLineSIMD(line, search_pattern, &skip_table, options.case_insensitive, &match_pos);
        }

        // Invert match if needed
        if (options.invert_match) found_match = !found_match;

        if (found_match) {
            // Split fields
            const match_idx: u32 = @intCast(matches.items.len);
            const field_count = try splitFieldsSIMD(text, line_start, line_end, options.field_separator, &fields, match_idx, allocator);

            try matches.append(allocator, .{
                .line_start = @intCast(line_start),
                .line_end = @intCast(line_end),
                .match_start = @intCast(match_pos),
                .match_end = @intCast(if (pattern.len > 0) match_pos + pattern.len else 0),
                .line_num = line_num,
                .field_count = field_count,
            });
        }

        line_start = line_end + 1;
        line_num += 1;
    }

    const total = matches.items.len;
    return AwkResult{
        .matches = try matches.toOwnedSlice(allocator),
        .fields = try fields.toOwnedSlice(allocator),
        .total_matches = total,
        .total_lines = line_num,
        .allocator = allocator,
    };
}

/// CPU-based AWK pattern matching with regex support
pub fn processAwkRegex(
    text: []const u8,
    pattern: []const u8,
    options: AwkOptions,
    allocator: std.mem.Allocator,
) !AwkResult {
    var matches: std.ArrayListUnmanaged(AwkMatchResult) = .{};
    errdefer matches.deinit(allocator);
    var fields: std.ArrayListUnmanaged(FieldInfo) = .{};
    errdefer fields.deinit(allocator);

    // Compile regex pattern
    var compiled_regex = regex_lib.Regex.compile(allocator, pattern, .{
        .case_insensitive = options.case_insensitive,
    }) catch {
        // If regex compilation fails, fall back to literal search
        return processAwk(text, pattern, options, allocator);
    };
    defer compiled_regex.deinit();

    var line_start: usize = 0;
    var line_num: u32 = 0;

    while (line_start < text.len) {
        // Find line end using SIMD
        const line_end = findNextNewlineSIMD(text, line_start);
        const line = text[line_start..line_end];

        // Regex pattern matching
        var match_result = compiled_regex.find(line, allocator) catch null;
        defer if (match_result) |*m| m.deinit();

        var found_match = match_result != null;

        // Invert match if needed
        if (options.invert_match) found_match = !found_match;

        if (found_match) {
            // Split fields
            const match_idx: u32 = @intCast(matches.items.len);
            const field_count = try splitFieldsSIMD(text, line_start, line_end, options.field_separator, &fields, match_idx, allocator);

            // Get match positions (0 if inverted match with no actual match)
            var match_start_pos: u32 = 0;
            var match_end_pos: u32 = 0;
            if (match_result) |match_info| {
                match_start_pos = @intCast(match_info.start);
                match_end_pos = @intCast(match_info.end);
            }

            try matches.append(allocator, .{
                .line_start = @intCast(line_start),
                .line_end = @intCast(line_end),
                .match_start = match_start_pos,
                .match_end = match_end_pos,
                .line_num = line_num,
                .field_count = field_count,
            });
        }

        line_start = line_end + 1;
        line_num += 1;
    }

    const total = matches.items.len;
    return AwkResult{
        .matches = try matches.toOwnedSlice(allocator),
        .fields = try fields.toOwnedSlice(allocator),
        .total_matches = total,
        .total_lines = line_num,
        .allocator = allocator,
    };
}

/// SIMD-optimized newline finder
fn findNextNewlineSIMD(text: []const u8, start: usize) usize {
    var i = start;

    // Search 32 bytes at a time
    while (i + 32 <= text.len) {
        const chunk: Vec32 = text[i..][0..32].*;
        const newlines = chunk == NEWLINE_VEC32;

        if (@reduce(.Or, newlines)) {
            // Find the first newline
            for (0..32) |j| {
                if (text[i + j] == '\n') return i + j;
            }
        }
        i += 32;
    }

    // Handle remaining bytes
    while (i < text.len) {
        if (text[i] == '\n') return i;
        i += 1;
    }

    return text.len;
}

/// SIMD-optimized line search
fn searchLineSIMD(line: []const u8, pattern: []const u8, skip_table: *const [256]u8, case_insensitive: bool, match_pos: *usize) bool {
    if (pattern.len == 0) return true;
    if (line.len < pattern.len) return false;

    var pos: usize = 0;

    while (pos + pattern.len <= line.len) {
        if (matchAtPositionSIMD(line, pos, pattern, case_insensitive)) {
            match_pos.* = pos;
            return true;
        }

        const skip_char = if (case_insensitive)
            toLowerChar(line[pos + pattern.len - 1])
        else
            line[pos + pattern.len - 1];
        const skip = skip_table[skip_char];
        pos += @max(skip, 1);
    }

    return false;
}

/// SIMD-optimized pattern matching at a specific position
inline fn matchAtPositionSIMD(text: []const u8, pos: usize, pattern: []const u8, case_insensitive: bool) bool {
    if (pos + pattern.len > text.len) return false;

    const text_slice = text[pos..][0..pattern.len];
    var offset: usize = 0;

    // Process 16 bytes at a time
    while (offset + 16 <= pattern.len) {
        const text_vec: Vec16 = text_slice[offset..][0..16].*;
        const pattern_vec: Vec16 = pattern[offset..][0..16].*;

        const cmp_result = if (case_insensitive)
            @as(Vec16, toLowerVec16(text_vec)) == pattern_vec
        else
            text_vec == pattern_vec;

        if (!@reduce(.And, cmp_result)) return false;
        offset += 16;
    }

    // Process remaining bytes
    while (offset < pattern.len) {
        var tc = text_slice[offset];
        const pc = pattern[offset];

        if (case_insensitive) {
            tc = toLowerChar(tc);
        }

        if (tc != pc) return false;
        offset += 1;
    }

    return true;
}

/// Vectorized lowercase conversion for Vec16
inline fn toLowerVec16(v: Vec16) Vec16 {
    const is_upper = (v >= UPPER_A_VEC16) & (v <= UPPER_Z_VEC16);
    return @select(u8, is_upper, v + CASE_DIFF_VEC16, v);
}

/// Scalar lowercase conversion
inline fn toLowerChar(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Convert slice to lowercase using SIMD
inline fn toLowerSlice(src: []const u8, dst: []u8) void {
    var i: usize = 0;
    // Process 16 bytes at a time
    while (i + 16 <= src.len) {
        const vec: Vec16 = src[i..][0..16].*;
        const lower = toLowerVec16(vec);
        dst[i..][0..16].* = lower;
        i += 16;
    }
    // Handle remaining bytes
    while (i < src.len) {
        dst[i] = toLowerChar(src[i]);
        i += 1;
    }
}

/// SIMD-optimized field splitting
fn splitFieldsSIMD(
    text: []const u8,
    line_start: usize,
    line_end: usize,
    field_sep: []const u8,
    fields: *std.ArrayListUnmanaged(FieldInfo),
    line_idx: u32,
    allocator: std.mem.Allocator,
) !u32 {
    const line = text[line_start..line_end];

    // For whitespace separator, use SIMD to find separators
    const is_whitespace_sep = field_sep.len == 0 or
        (field_sep.len == 1 and (field_sep[0] == ' ' or field_sep[0] == '\t'));

    var field_idx: u32 = 1;
    var field_start: u32 = 0;
    var in_field = false;
    var i: usize = 0;

    if (is_whitespace_sep and line.len >= 32) {
        // Use SIMD to find whitespace
        while (i + 32 <= line.len) {
            const chunk: Vec32 = line[i..][0..32].*;
            const spaces = chunk == SPACE_VEC32;
            const tabs = chunk == TAB_VEC32;
            const whitespace = spaces | tabs;

            if (@reduce(.Or, whitespace)) {
                // Process byte by byte in this chunk
                for (0..32) |j| {
                    const is_sep = line[i + j] == ' ' or line[i + j] == '\t';
                    if (!is_sep and !in_field) {
                        in_field = true;
                        field_start = @intCast(i + j);
                    } else if (is_sep and in_field) {
                        try fields.append(allocator, .{
                            .line_idx = line_idx,
                            .field_idx = field_idx,
                            .start_offset = field_start,
                            .end_offset = @intCast(i + j),
                        });
                        field_idx += 1;
                        in_field = false;
                    }
                }
            } else {
                // No whitespace in this chunk
                if (!in_field) {
                    in_field = true;
                    field_start = @intCast(i);
                }
            }
            i += 32;
        }
    }

    // Process remaining bytes
    while (i < line.len) {
        const is_sep = isSeparatorSIMD(line[i], field_sep);
        if (!is_sep and !in_field) {
            in_field = true;
            field_start = @intCast(i);
        } else if (is_sep and in_field) {
            try fields.append(allocator, .{
                .line_idx = line_idx,
                .field_idx = field_idx,
                .start_offset = field_start,
                .end_offset = @intCast(i),
            });
            field_idx += 1;
            in_field = false;
        }
        i += 1;
    }

    if (in_field) {
        try fields.append(allocator, .{
            .line_idx = line_idx,
            .field_idx = field_idx,
            .start_offset = field_start,
            .end_offset = @intCast(line.len),
        });
        field_idx += 1;
    }

    return field_idx - 1;
}

inline fn isSeparatorSIMD(c: u8, sep: []const u8) bool {
    // Default whitespace separator
    if (sep.len == 0) return c == ' ' or c == '\t';

    for (sep) |s| {
        if (c == s) return true;
    }
    return false;
}

/// CPU-based gsub implementation - find all pattern matches with SIMD
pub fn findSubstitutions(
    text: []const u8,
    pattern: []const u8,
    options: AwkOptions,
    allocator: std.mem.Allocator,
) ![]SubstitutionResult {
    var matches: std.ArrayListUnmanaged(SubstitutionResult) = .{};
    errdefer matches.deinit(allocator);

    if (pattern.len == 0) return try matches.toOwnedSlice(allocator);

    // Pre-compute lowercase pattern if case insensitive
    var lower_pattern_buf: [1024]u8 = undefined;
    const search_pattern = if (options.case_insensitive and pattern.len <= 1024) blk: {
        toLowerSlice(pattern, lower_pattern_buf[0..pattern.len]);
        break :blk lower_pattern_buf[0..pattern.len];
    } else pattern;

    const skip_table = gpu.buildSkipTable(search_pattern, options.case_insensitive);

    var pos: usize = 0;
    var line_num: u32 = 0;

    while (pos + pattern.len <= text.len) {
        // Track line numbers
        if (pos > 0 and text[pos - 1] == '\n') line_num += 1;

        if (matchAtPositionSIMD(text, pos, search_pattern, options.case_insensitive)) {
            try matches.append(allocator, .{
                .position = @intCast(pos),
                .match_len = @intCast(pattern.len),
                .line_num = line_num,
            });
            pos += pattern.len; // Non-overlapping matches
        } else {
            const skip_char = if (options.case_insensitive)
                toLowerChar(text[pos + pattern.len - 1])
            else
                text[pos + pattern.len - 1];
            const skip = skip_table[skip_char];
            pos += @max(skip, 1);
        }
    }

    return try matches.toOwnedSlice(allocator);
}

/// CPU-based gsub implementation with regex support
pub fn findSubstitutionsRegex(
    text: []const u8,
    pattern: []const u8,
    options: AwkOptions,
    allocator: std.mem.Allocator,
) ![]SubstitutionResult {
    var matches: std.ArrayListUnmanaged(SubstitutionResult) = .{};
    errdefer matches.deinit(allocator);

    if (pattern.len == 0) return try matches.toOwnedSlice(allocator);

    // Compile regex pattern
    var compiled_regex = regex_lib.Regex.compile(allocator, pattern, .{
        .case_insensitive = options.case_insensitive,
    }) catch {
        // If regex compilation fails, fall back to literal search
        return findSubstitutions(text, pattern, options, allocator);
    };
    defer compiled_regex.deinit();

    var pos: usize = 0;
    var line_num: u32 = 0;

    while (pos < text.len) {
        // Track line numbers
        if (pos > 0 and text[pos - 1] == '\n') line_num += 1;

        // Try to find a match starting at or after pos
        var match_opt = compiled_regex.findAt(text, pos, allocator) catch null;
        if (match_opt) |*match| {
            defer match.deinit();
            try matches.append(allocator, .{
                .position = @intCast(match.start),
                .match_len = @intCast(match.end - match.start),
                .line_num = line_num,
            });
            // Move past this match (non-overlapping)
            pos = match.end;
            if (pos == match.start) pos += 1; // Prevent infinite loop on zero-width matches
        } else {
            break; // No more matches
        }
    }

    return try matches.toOwnedSlice(allocator);
}

/// Apply regex substitutions to text (handles variable-length matches)
pub fn applySubstitutionsRegex(
    text: []const u8,
    substitutions: []const SubstitutionResult,
    replacement: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (substitutions.len == 0) {
        const result = try allocator.alloc(u8, text.len);
        @memcpy(result, text);
        return result;
    }

    // Calculate new length (each match can have different length)
    var total_removed: usize = 0;
    for (substitutions) |sub| {
        total_removed += sub.match_len;
    }
    const total_added = replacement.len * substitutions.len;
    const new_len = text.len - total_removed + total_added;

    var result = try allocator.alloc(u8, new_len);

    var src_pos: usize = 0;
    var dst_pos: usize = 0;

    for (substitutions) |sub| {
        const match_pos = sub.position;

        // Copy text before match
        const before_len = match_pos - src_pos;
        if (before_len > 0) {
            @memcpy(result[dst_pos..][0..before_len], text[src_pos..][0..before_len]);
            dst_pos += before_len;
        }

        // Copy replacement
        if (replacement.len > 0) {
            @memcpy(result[dst_pos..][0..replacement.len], replacement);
            dst_pos += replacement.len;
        }

        src_pos = match_pos + sub.match_len;
    }

    // Copy remaining text
    const remaining = text.len - src_pos;
    if (remaining > 0) {
        @memcpy(result[dst_pos..][0..remaining], text[src_pos..][0..remaining]);
    }

    return result;
}

/// Apply substitutions to text with SIMD-optimized memcpy
pub fn applySubstitutions(
    text: []const u8,
    substitutions: []const SubstitutionResult,
    pattern_len: usize,
    replacement: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (substitutions.len == 0) {
        const result = try allocator.alloc(u8, text.len);
        @memcpy(result, text);
        return result;
    }

    // Calculate new length
    const len_diff: isize = @as(isize, @intCast(replacement.len)) - @as(isize, @intCast(pattern_len));
    const new_len: usize = @intCast(@as(isize, @intCast(text.len)) + len_diff * @as(isize, @intCast(substitutions.len)));

    var result = try allocator.alloc(u8, new_len);

    var src_pos: usize = 0;
    var dst_pos: usize = 0;

    for (substitutions) |sub| {
        const match_pos = sub.position;

        // Copy text before match (SIMD-friendly memcpy)
        const before_len = match_pos - src_pos;
        if (before_len > 0) {
            @memcpy(result[dst_pos..][0..before_len], text[src_pos..][0..before_len]);
            dst_pos += before_len;
        }

        // Copy replacement
        if (replacement.len > 0) {
            @memcpy(result[dst_pos..][0..replacement.len], replacement);
            dst_pos += replacement.len;
        }

        src_pos = match_pos + pattern_len;
    }

    // Copy remaining text
    const remaining = text.len - src_pos;
    if (remaining > 0) {
        @memcpy(result[dst_pos..][0..remaining], text[src_pos..][0..remaining]);
    }

    return result;
}
