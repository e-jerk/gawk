#include <metal_stdlib>
#include "string_ops.h"
#include "regex_ops.h"
using namespace metal;

// GPU-Accelerated AWK Operations for Metal
// Optimized with uchar4 vector types for SIMD operations
// Note: Metal supports up to 4-element vectors for uchar

constant uint FLAG_CASE_INSENSITIVE = 1u;
constant uint FLAG_INVERT_MATCH = 32u;

struct AwkConfig {
    uint text_len;
    uint pattern_len;
    uint field_sep_len;
    uint num_fields_requested;
    uint flags;
    uint max_results;
    uint max_fields;
    uint replacement_len;
};

struct AwkMatchResult {
    uint line_start;
    uint line_end;
    uint match_start;
    uint match_end;
    uint line_num;
    uint field_count;
    uint _pad1;
    uint _pad2;
};

struct FieldInfo {
    uint line_idx;
    uint field_idx;
    uint start_offset;
    uint end_offset;
};

// Vectorized separator check using uchar4
inline bool4 is_separator4(uchar4 c, device const uchar* field_sep, uint field_sep_len) {
    bool4 result = bool4(false);
    for (uint i = 0; i < field_sep_len; i++) {
        result = result || (c == uchar4(field_sep[i]));
    }
    return result;
}

// Helper: check if character is a field separator
inline bool is_field_separator(uchar c, device const uchar* field_sep, uint field_sep_len) {
    for (uint i = 0; i < field_sep_len; i++) {
        if (c == field_sep[i]) return true;
    }
    return false;
}

// Optimized pattern matching kernel using vectorized operations
kernel void awk_pattern_match(
    device const uchar* text [[buffer(0)]],
    device const uchar* pattern [[buffer(1)]],
    device const uchar* skip_table [[buffer(2)]],
    device const AwkConfig& config [[buffer(3)]],
    device AwkMatchResult* results [[buffer(4)]],
    device atomic_uint* match_count [[buffer(5)]],
    device const uint* line_offsets [[buffer(6)]],
    device const uint* line_lengths [[buffer(7)]],
    uint gid [[thread_position_in_grid]],
    uint num_threads [[threads_per_grid]]
) {
    if (gid >= num_threads) return;

    uint line_start = line_offsets[gid];
    uint line_len = line_lengths[gid];
    uint line_end = line_start + line_len;

    bool case_insensitive = (config.flags & FLAG_CASE_INSENSITIVE) != 0;
    bool invert_match = (config.flags & FLAG_INVERT_MATCH) != 0;

    bool found_match = false;
    uint match_pos = 0;

    // If no pattern, match all lines
    if (config.pattern_len == 0) {
        found_match = true;
    } else if (line_len >= config.pattern_len) {
        // Boyer-Moore-Horspool search with vectorized inner loop
        uint pos = 0;
        uint pattern_len = config.pattern_len;

        while (pos + pattern_len <= line_len && !found_match) {
            device const uchar* text_ptr = text + line_start + pos;
            uint remaining = pattern_len;
            uint offset = 0;
            bool match = true;

            // Process 4 bytes at a time using uchar4
            while (remaining >= 4 && match) {
                uchar4 p = uchar4(pattern[offset], pattern[offset+1], pattern[offset+2], pattern[offset+3]);
                uchar4 t = uchar4(text_ptr[offset], text_ptr[offset+1], text_ptr[offset+2], text_ptr[offset+3]);
                if (!match4(p, t, case_insensitive)) {
                    match = false;
                }
                offset += 4;
                remaining -= 4;
            }

            // Process remaining bytes one at a time
            while (remaining > 0 && match) {
                if (!char_match(pattern[offset], text_ptr[offset], case_insensitive)) {
                    match = false;
                }
                offset++;
                remaining--;
            }

            if (match) {
                found_match = true;
                match_pos = pos;
            } else {
                // Use skip table for next position
                uchar skip_char = text_ptr[pattern_len - 1];
                uint skip = skip_table[skip_char];
                pos += max(skip, 1u);
            }
        }
    }

    // Apply invert match
    if (invert_match) found_match = !found_match;

    if (found_match) {
        uint idx = atomic_fetch_add_explicit(match_count, 1, memory_order_relaxed);
        if (idx < config.max_results) {
            results[idx].line_start = line_start;
            results[idx].line_end = line_end;
            results[idx].match_start = config.pattern_len > 0 ? match_pos : 0;
            results[idx].match_end = config.pattern_len > 0 ? match_pos + config.pattern_len : 0;
            results[idx].line_num = gid;
            results[idx].field_count = 0;
        }
    }
}

// Optimized field splitting kernel with vectorized separator detection
kernel void awk_field_split(
    device const uchar* text [[buffer(0)]],
    device const uchar* field_sep [[buffer(1)]],
    device const AwkConfig& config [[buffer(2)]],
    device AwkMatchResult* matches [[buffer(3)]],
    device FieldInfo* fields [[buffer(4)]],
    device atomic_uint* field_count [[buffer(5)]],
    uint gid [[thread_position_in_grid]],
    uint num_matches [[threads_per_grid]]
) {
    if (gid >= num_matches) return;

    uint line_start = matches[gid].line_start;
    uint line_end = matches[gid].line_end;
    uint line_len = line_end - line_start;

    uint field_idx = 1;  // AWK fields are 1-indexed
    uint field_start_pos = 0;
    bool in_field = false;

    // Process 4 bytes at a time where possible
    uint i = 0;
    device const uchar* line_ptr = text + line_start;

    // Main loop - process 4 bytes at a time for separator detection
    while (i + 4 <= line_len) {
        uchar4 chars = uchar4(line_ptr[i], line_ptr[i+1], line_ptr[i+2], line_ptr[i+3]);
        bool4 sep_mask = is_separator4(chars, field_sep, config.field_sep_len);

        // Process each byte in the vector
        for (uint j = 0; j < 4; j++) {
            bool is_sep = sep_mask[j];

            if (!is_sep && !in_field) {
                in_field = true;
                field_start_pos = i + j;
            } else if (is_sep && in_field) {
                uint idx = atomic_fetch_add_explicit(field_count, 1, memory_order_relaxed);
                if (idx < config.max_fields) {
                    fields[idx].line_idx = gid;
                    fields[idx].field_idx = field_idx;
                    fields[idx].start_offset = field_start_pos;
                    fields[idx].end_offset = i + j;
                }
                field_idx++;
                in_field = false;
            }
        }
        i += 4;
    }

    // Handle remaining bytes
    while (i < line_len) {
        uchar c = line_ptr[i];
        bool is_sep = is_field_separator(c, field_sep, config.field_sep_len);

        if (!is_sep && !in_field) {
            in_field = true;
            field_start_pos = i;
        } else if (is_sep && in_field) {
            uint idx = atomic_fetch_add_explicit(field_count, 1, memory_order_relaxed);
            if (idx < config.max_fields) {
                fields[idx].line_idx = gid;
                fields[idx].field_idx = field_idx;
                fields[idx].start_offset = field_start_pos;
                fields[idx].end_offset = i;
            }
            field_idx++;
            in_field = false;
        }
        i++;
    }

    // Handle last field if line doesn't end with separator
    if (in_field) {
        uint idx = atomic_fetch_add_explicit(field_count, 1, memory_order_relaxed);
        if (idx < config.max_fields) {
            fields[idx].line_idx = gid;
            fields[idx].field_idx = field_idx;
            fields[idx].start_offset = field_start_pos;
            fields[idx].end_offset = line_len;
        }
        field_idx++;
    }

    matches[gid].field_count = field_idx - 1;
}

// Optimized line boundary detection with vectorized newline search
kernel void find_line_boundaries(
    device const uchar* text [[buffer(0)]],
    device uint* line_offsets [[buffer(1)]],
    device uint* line_lengths [[buffer(2)]],
    device atomic_uint* line_count [[buffer(3)]],
    device const AwkConfig& config [[buffer(4)]],
    uint gid [[thread_position_in_grid]],
    uint num_threads [[threads_per_grid]]
) {
    uint chunk_size = (config.text_len + num_threads - 1) / num_threads;
    uint start_pos = gid * chunk_size;
    uint end_pos = min(start_pos + chunk_size, config.text_len);

    if (start_pos >= config.text_len) return;

    // Thread 0 always starts a line at position 0
    if (gid == 0) {
        uint idx = atomic_fetch_add_explicit(line_count, 1, memory_order_relaxed);
        line_offsets[idx] = 0;
    }

    // Vectorized newline search - check 4 bytes at a time
    device const uchar* text_ptr = text + start_pos;
    uint remaining = end_pos - start_pos;
    uint pos = 0;

    // Process 4 bytes at a time using uchar4
    while (remaining >= 4) {
        uchar4 chars = uchar4(text_ptr[pos], text_ptr[pos+1], text_ptr[pos+2], text_ptr[pos+3]);
        bool4 newline_mask = (chars == uchar4('\n'));

        // Check each byte for newline
        for (uint j = 0; j < 4; j++) {
            uint absolute_pos = start_pos + pos + j;
            if (newline_mask[j] && absolute_pos + 1 < config.text_len) {
                uint idx = atomic_fetch_add_explicit(line_count, 1, memory_order_relaxed);
                line_offsets[idx] = absolute_pos + 1;
            }
        }
        pos += 4;
        remaining -= 4;
    }

    // Process remaining bytes one at a time
    while (remaining > 0) {
        uint absolute_pos = start_pos + pos;
        if (text_ptr[pos] == '\n' && absolute_pos + 1 < config.text_len) {
            uint idx = atomic_fetch_add_explicit(line_count, 1, memory_order_relaxed);
            line_offsets[idx] = absolute_pos + 1;
        }
        pos++;
        remaining--;
    }
}

// ============================================================================
// Regex Pattern Matching Kernel
// Uses Thompson NFA execution from regex_ops.h
// ============================================================================

struct AwkRegexConfig {
    uint text_len;
    uint num_states;
    uint start_state;
    uint header_flags;
    uint num_bitmaps;
    uint max_results;
    uint flags;
    uint _pad;
};

// GPU-accelerated regex pattern matching using NFA execution
kernel void awk_regex_match(
    device const uchar* text [[buffer(0)]],
    constant RegexState* states [[buffer(1)]],
    constant uint* bitmaps [[buffer(2)]],
    constant AwkRegexConfig& config [[buffer(3)]],
    constant RegexHeader& header [[buffer(4)]],
    device AwkMatchResult* results [[buffer(5)]],
    device atomic_uint* match_count [[buffer(6)]],
    device const uint* line_offsets [[buffer(7)]],
    device const uint* line_lengths [[buffer(8)]],
    uint gid [[thread_position_in_grid]],
    uint num_threads [[threads_per_grid]]
) {
    if (gid >= num_threads) return;

    uint line_start = line_offsets[gid];
    uint line_len = line_lengths[gid];
    uint line_end = line_start + line_len;

    bool invert_match = (config.flags & FLAG_INVERT_MATCH) != 0;

    // Use regex_find to search for pattern in this line
    uint match_start, match_end;
    bool found = regex_find(
        &header,
        states,
        bitmaps,
        text + line_start,
        line_len,
        0,  // Start searching from beginning of line
        &match_start,
        &match_end
    );

    // Apply invert match
    if (invert_match) found = !found;

    if (found) {
        uint idx = atomic_fetch_add_explicit(match_count, 1, memory_order_relaxed);
        if (idx < config.max_results) {
            results[idx].line_start = line_start;
            results[idx].line_end = line_end;
            results[idx].match_start = invert_match ? 0 : match_start;
            results[idx].match_end = invert_match ? 0 : match_end;
            results[idx].line_num = gid;
            results[idx].field_count = 0;
        }
    }
}

// GPU-accelerated regex gsub - find all matches for substitution
kernel void awk_regex_gsub(
    device const uchar* text [[buffer(0)]],
    constant RegexState* states [[buffer(1)]],
    constant uint* bitmaps [[buffer(2)]],
    constant AwkRegexConfig& config [[buffer(3)]],
    constant RegexHeader& header [[buffer(4)]],
    device RegexMatchResult* results [[buffer(5)]],
    device atomic_uint* match_count [[buffer(6)]],
    uint gid [[thread_position_in_grid]],
    uint num_threads [[threads_per_grid]]
) {
    // Each thread handles a chunk of the text to find all regex matches
    uint chunk_size = (config.text_len + num_threads - 1) / num_threads;
    uint start_pos = gid * chunk_size;
    uint end_pos = min(start_pos + chunk_size, config.text_len);

    if (start_pos >= config.text_len) return;

    uint pos = start_pos;
    while (pos < end_pos) {
        uint match_start, match_end;
        bool found = regex_find(
            &header,
            states,
            bitmaps,
            text,
            config.text_len,
            pos,
            &match_start,
            &match_end
        );

        if (!found || match_start >= end_pos) break;

        // Record this match
        uint idx = atomic_fetch_add_explicit(match_count, 1, memory_order_relaxed);
        if (idx < config.max_results) {
            results[idx].start = match_start;
            results[idx].end = match_end;
            results[idx].pattern_idx = 0;
            results[idx].flags = 1;  // FLAG_VALID
        }

        // Move past this match (avoid infinite loop on zero-width matches)
        pos = (match_end > match_start) ? match_end : match_start + 1;
    }
}
