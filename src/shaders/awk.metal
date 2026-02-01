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

// ============================================================================
// GPU Bytecode Virtual Machine
// Executes compiled AWK bytecode on GPU for full feature parity
// ============================================================================

// Opcodes - must match bytecode.zig (only defining used ones to avoid -Werror warnings)
#define OP_NOP 0u
#define OP_PUSH_NUM 1u
#define OP_PUSH_FIELD 3u
#define OP_PUSH_VAR 4u
#define OP_PUSH_SPECIAL 5u
#define OP_POP 6u
#define OP_DUP 7u
#define OP_ADD 10u
#define OP_SUB 11u
#define OP_MUL 12u
#define OP_DIV 13u
#define OP_MOD 14u
#define OP_POW 15u
#define OP_NEG 16u
#define OP_LT 20u
#define OP_LE 21u
#define OP_GT 22u
#define OP_GE 23u
#define OP_EQ 24u
#define OP_NE 25u
#define OP_AND 30u
#define OP_OR 31u
#define OP_NOT 32u
#define OP_LENGTH 41u
#define OP_SIN 50u
#define OP_COS 51u
#define OP_SQRT 52u
#define OP_INT_FN 53u
#define OP_LOG_FN 54u
#define OP_EXP_FN 55u
#define OP_JMP 60u
#define OP_JMP_IF 61u
#define OP_JMP_IF_NOT 62u
#define OP_HALT 65u
#define OP_STORE_VAR 70u
#define OP_PRINT 80u
#define OP_NEXT_LINE 95u
#define OP_EXIT_PROG 96u

// Special variable types
#define SVAR_NR 0u
#define SVAR_NF 1u
#define SVAR_FNR 2u

// GPU Value type (8 bytes)
struct GpuValue {
    float number;
    uint str_offset;  // 0 = numeric, >0 = string offset in string pool
};

// Bytecode instruction (4 bytes)
struct Instruction {
    uchar opcode;
    uchar arg1;
    uchar arg2;
    uchar arg3;
};

// VM execution configuration
struct VmConfig {
    uint num_instructions;
    uint num_constants;
    uint num_variables;
    uint stack_size;
    uint max_output_per_thread;
    uint main_offset;
    uint flags;
    uint _pad;
};

// Per-thread VM state
struct ThreadState {
    GpuValue stack[32];     // Evaluation stack
    GpuValue variables[16]; // Local variables
    uint sp;                // Stack pointer
    uint pc;                // Program counter
    uint output_pos;        // Position in output buffer
    uint line_num;          // Current line number (NR)
    uint field_count;       // Number of fields (NF)
    bool halted;            // Execution halted
    bool next_line;         // Skip to next line
};

// Helper: check if value is truthy
inline bool is_truthy(GpuValue v) {
    if (v.str_offset != 0) return true;  // Non-empty string
    return v.number != 0.0f;
}

// Helper: get string length from string pool
inline uint get_string_len(device const uchar* str_pool, uint offset) {
    if (offset == 0) return 0;
    // String format: [len:u16][chars...]
    return (uint(str_pool[offset]) | (uint(str_pool[offset + 1]) << 8));
}

// Helper: extract field from line
inline void extract_field(
    device const uchar* text,
    uint line_start,
    uint line_len,
    uint field_num,
    device const uchar* field_sep,
    uint field_sep_len,
    thread uint* out_start,
    thread uint* out_len
) {
    if (field_num == 0) {
        // $0 = entire line
        *out_start = line_start;
        *out_len = line_len;
        return;
    }

    uint current_field = 1;
    uint field_start = 0;
    bool in_field = false;
    device const uchar* line = text + line_start;

    for (uint i = 0; i < line_len; i++) {
        bool is_sep = false;
        for (uint j = 0; j < field_sep_len; j++) {
            if (line[i] == field_sep[j]) {
                is_sep = true;
                break;
            }
        }

        if (!is_sep && !in_field) {
            in_field = true;
            field_start = i;
        } else if (is_sep && in_field) {
            if (current_field == field_num) {
                *out_start = line_start + field_start;
                *out_len = i - field_start;
                return;
            }
            current_field++;
            in_field = false;
        }
    }

    // Handle last field
    if (in_field && current_field == field_num) {
        *out_start = line_start + field_start;
        *out_len = line_len - field_start;
        return;
    }

    // Field not found
    *out_start = 0;
    *out_len = 0;
}

// GPU Bytecode VM Kernel - executes AWK program for each line
kernel void awk_vm_execute(
    device const uchar* text [[buffer(0)]],
    device const Instruction* bytecode [[buffer(1)]],
    device const float* num_constants [[buffer(2)]],
    device const uchar* str_pool [[buffer(3)]],
    device const uchar* field_sep [[buffer(4)]],
    device const VmConfig& config [[buffer(5)]],
    device uchar* output [[buffer(6)]],
    device atomic_uint* output_offsets [[buffer(7)]],
    device const uint* line_offsets [[buffer(8)]],
    device const uint* line_lengths [[buffer(9)]],
    uint gid [[thread_position_in_grid]],
    uint num_threads [[threads_per_grid]]
) {
    if (gid >= num_threads) return;

    uint line_start = line_offsets[gid];
    uint line_len = line_lengths[gid];

    // Initialize thread state
    ThreadState state;
    state.sp = 0;
    state.pc = config.main_offset;
    state.output_pos = gid * config.max_output_per_thread;
    state.line_num = gid + 1;  // NR is 1-indexed
    state.halted = false;
    state.next_line = false;

    // Count fields
    state.field_count = 0;
    bool in_field = false;
    for (uint i = 0; i < line_len; i++) {
        bool is_sep = false;
        for (uint j = 0; j < 1; j++) {  // Default whitespace
            if (text[line_start + i] == ' ' || text[line_start + i] == '\t') {
                is_sep = true;
                break;
            }
        }
        if (!is_sep && !in_field) {
            in_field = true;
            state.field_count++;
        } else if (is_sep) {
            in_field = false;
        }
    }

    // Initialize variables to 0
    for (uint i = 0; i < 16; i++) {
        state.variables[i].number = 0.0f;
        state.variables[i].str_offset = 0;
    }

    // Execute bytecode
    uint max_iterations = 10000;
    uint iterations = 0;

    while (!state.halted && !state.next_line && iterations < max_iterations) {
        iterations++;

        Instruction inst = bytecode[state.pc];
        state.pc++;

        switch (inst.opcode) {
            case OP_NOP:
                break;

            case OP_PUSH_NUM: {
                uint const_idx = uint(inst.arg1) | (uint(inst.arg2) << 8);
                state.stack[state.sp].number = num_constants[const_idx];
                state.stack[state.sp].str_offset = 0;
                state.sp++;
                break;
            }

            case OP_PUSH_FIELD: {
                uint field_num = inst.arg1;
                uint f_start, f_len;
                extract_field(text, line_start, line_len, field_num, field_sep, 1, &f_start, &f_len);
                // For now, convert field to number if possible
                // TODO: proper string handling
                float val = 0.0f;
                for (uint i = 0; i < f_len && i < 20; i++) {
                    uchar c = text[f_start + i];
                    if (c >= '0' && c <= '9') {
                        val = val * 10.0f + float(c - '0');
                    } else if (c == '-' && i == 0) {
                        // Handle negative
                    } else if (c != '.' && c != ' ') {
                        break;
                    }
                }
                state.stack[state.sp].number = val;
                state.stack[state.sp].str_offset = f_start | (f_len << 16);  // Pack offset and length
                state.sp++;
                break;
            }

            case OP_PUSH_VAR: {
                uint var_idx = inst.arg1;
                state.stack[state.sp] = state.variables[var_idx];
                state.sp++;
                break;
            }

            case OP_PUSH_SPECIAL: {
                float val = 0.0f;
                switch (inst.arg1) {
                    case SVAR_NR: val = float(state.line_num); break;
                    case SVAR_NF: val = float(state.field_count); break;
                    case SVAR_FNR: val = float(state.line_num); break;
                    default: break;
                }
                state.stack[state.sp].number = val;
                state.stack[state.sp].str_offset = 0;
                state.sp++;
                break;
            }

            case OP_POP:
                if (state.sp > 0) state.sp--;
                break;

            case OP_DUP:
                if (state.sp > 0) {
                    state.stack[state.sp] = state.stack[state.sp - 1];
                    state.sp++;
                }
                break;

            case OP_ADD: {
                if (state.sp >= 2) {
                    state.sp--;
                    state.stack[state.sp - 1].number += state.stack[state.sp].number;
                }
                break;
            }

            case OP_SUB: {
                if (state.sp >= 2) {
                    state.sp--;
                    state.stack[state.sp - 1].number -= state.stack[state.sp].number;
                }
                break;
            }

            case OP_MUL: {
                if (state.sp >= 2) {
                    state.sp--;
                    state.stack[state.sp - 1].number *= state.stack[state.sp].number;
                }
                break;
            }

            case OP_DIV: {
                if (state.sp >= 2) {
                    state.sp--;
                    float divisor = state.stack[state.sp].number;
                    if (divisor != 0.0f) {
                        state.stack[state.sp - 1].number /= divisor;
                    }
                }
                break;
            }

            case OP_MOD: {
                if (state.sp >= 2) {
                    state.sp--;
                    float b = state.stack[state.sp].number;
                    if (b != 0.0f) {
                        state.stack[state.sp - 1].number = fmod(state.stack[state.sp - 1].number, b);
                    }
                }
                break;
            }

            case OP_POW: {
                if (state.sp >= 2) {
                    state.sp--;
                    state.stack[state.sp - 1].number = pow(state.stack[state.sp - 1].number, state.stack[state.sp].number);
                }
                break;
            }

            case OP_NEG:
                if (state.sp > 0) {
                    state.stack[state.sp - 1].number = -state.stack[state.sp - 1].number;
                }
                break;

            case OP_LT:
            case OP_LE:
            case OP_GT:
            case OP_GE:
            case OP_EQ:
            case OP_NE: {
                if (state.sp >= 2) {
                    state.sp--;
                    float a = state.stack[state.sp - 1].number;
                    float b = state.stack[state.sp].number;
                    bool result = false;
                    switch (inst.opcode) {
                        case OP_LT: result = a < b; break;
                        case OP_LE: result = a <= b; break;
                        case OP_GT: result = a > b; break;
                        case OP_GE: result = a >= b; break;
                        case OP_EQ: result = a == b; break;
                        case OP_NE: result = a != b; break;
                    }
                    state.stack[state.sp - 1].number = result ? 1.0f : 0.0f;
                    state.stack[state.sp - 1].str_offset = 0;
                }
                break;
            }

            case OP_AND: {
                if (state.sp >= 2) {
                    state.sp--;
                    bool result = is_truthy(state.stack[state.sp - 1]) && is_truthy(state.stack[state.sp]);
                    state.stack[state.sp - 1].number = result ? 1.0f : 0.0f;
                    state.stack[state.sp - 1].str_offset = 0;
                }
                break;
            }

            case OP_OR: {
                if (state.sp >= 2) {
                    state.sp--;
                    bool result = is_truthy(state.stack[state.sp - 1]) || is_truthy(state.stack[state.sp]);
                    state.stack[state.sp - 1].number = result ? 1.0f : 0.0f;
                    state.stack[state.sp - 1].str_offset = 0;
                }
                break;
            }

            case OP_NOT:
                if (state.sp > 0) {
                    state.stack[state.sp - 1].number = is_truthy(state.stack[state.sp - 1]) ? 0.0f : 1.0f;
                    state.stack[state.sp - 1].str_offset = 0;
                }
                break;

            case OP_LENGTH: {
                if (state.sp > 0) {
                    uint str_info = state.stack[state.sp - 1].str_offset;
                    uint len = (str_info >> 16) & 0xFFFF;
                    state.stack[state.sp - 1].number = float(len);
                    state.stack[state.sp - 1].str_offset = 0;
                }
                break;
            }

            case OP_SIN:
                if (state.sp > 0) {
                    state.stack[state.sp - 1].number = sin(state.stack[state.sp - 1].number);
                }
                break;

            case OP_COS:
                if (state.sp > 0) {
                    state.stack[state.sp - 1].number = cos(state.stack[state.sp - 1].number);
                }
                break;

            case OP_SQRT:
                if (state.sp > 0) {
                    state.stack[state.sp - 1].number = sqrt(state.stack[state.sp - 1].number);
                }
                break;

            case OP_INT_FN:
                if (state.sp > 0) {
                    state.stack[state.sp - 1].number = trunc(state.stack[state.sp - 1].number);
                }
                break;

            case OP_LOG_FN:
                if (state.sp > 0) {
                    state.stack[state.sp - 1].number = log(state.stack[state.sp - 1].number);
                }
                break;

            case OP_EXP_FN:
                if (state.sp > 0) {
                    state.stack[state.sp - 1].number = exp(state.stack[state.sp - 1].number);
                }
                break;

            case OP_JMP: {
                uint offset = uint(inst.arg1) | (uint(inst.arg2) << 8);
                state.pc = offset;
                break;
            }

            case OP_JMP_IF: {
                if (state.sp > 0) {
                    state.sp--;
                    if (is_truthy(state.stack[state.sp])) {
                        uint offset = uint(inst.arg1) | (uint(inst.arg2) << 8);
                        state.pc = offset;
                    }
                }
                break;
            }

            case OP_JMP_IF_NOT: {
                if (state.sp > 0) {
                    state.sp--;
                    if (!is_truthy(state.stack[state.sp])) {
                        uint offset = uint(inst.arg1) | (uint(inst.arg2) << 8);
                        state.pc = offset;
                    }
                }
                break;
            }

            case OP_STORE_VAR: {
                uint var_idx = inst.arg1;
                if (state.sp > 0 && var_idx < 16) {
                    state.variables[var_idx] = state.stack[state.sp - 1];
                }
                break;
            }

            case OP_PRINT: {
                uint num_args = inst.arg1;
                // Output values to per-thread buffer
                uint out_pos = state.output_pos;
                uint max_out = gid * config.max_output_per_thread + config.max_output_per_thread;

                // Pop all values first (they come off in reverse order)
                GpuValue print_vals[16];
                uint actual_args = min(num_args, 16u);
                for (uint i = 0; i < actual_args && state.sp > 0; i++) {
                    state.sp--;
                    print_vals[i] = state.stack[state.sp];
                }

                // Output in reverse order (original push order)
                for (uint i = actual_args; i > 0 && out_pos < max_out; i--) {
                    GpuValue val = print_vals[i - 1];

                    if (val.str_offset != 0) {
                        // Output string field
                        uint f_start = val.str_offset & 0xFFFF;
                        uint f_len = (val.str_offset >> 16) & 0xFFFF;
                        for (uint j = 0; j < f_len && out_pos < max_out; j++) {
                            output[out_pos++] = text[f_start + j];
                        }
                    } else {
                        // Output number
                        int n = int(val.number);
                        if (n < 0) {
                            output[out_pos++] = '-';
                            n = -n;
                        }
                        if (n == 0) {
                            output[out_pos++] = '0';
                        } else {
                            uchar digits[20];
                            uint num_digits = 0;
                            while (n > 0 && num_digits < 20) {
                                digits[num_digits++] = '0' + (n % 10);
                                n /= 10;
                            }
                            for (uint j = num_digits; j > 0 && out_pos < max_out; j--) {
                                output[out_pos++] = digits[j - 1];
                            }
                        }
                    }

                    // Add OFS between values (except last)
                    if (i > 1 && out_pos < max_out) {
                        output[out_pos++] = ' ';
                    }
                }

                // Add ORS (newline)
                if (out_pos < max_out) {
                    output[out_pos++] = '\n';
                }

                state.output_pos = out_pos;
                break;
            }

            case OP_NEXT_LINE:
                state.next_line = true;
                break;

            case OP_EXIT_PROG:
            case OP_HALT:
                state.halted = true;
                break;

            default:
                break;
        }
    }

    // Record output length
    uint output_len = state.output_pos - (gid * config.max_output_per_thread);
    atomic_store_explicit(&output_offsets[gid], output_len, memory_order_relaxed);
}
