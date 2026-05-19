#ifndef REGEX_OPS_H
#define REGEX_OPS_H

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// GPU Regex Operations - Common Metal Functions
// Shared across grep, sed, awk utilities
// Implements Thompson NFA execution with vectorized character class matching
// ============================================================================

// Maximum states supported per regex pattern
#define MAX_REGEX_STATES 256
#define MAX_CAPTURE_GROUPS 16

// ----------------------------------------------------------------------------
// NFA State Types
// ----------------------------------------------------------------------------

// Must match the Zig StateType enum
enum RegexStateType : uchar {
    STATE_LITERAL = 0,        // Match single character
    STATE_CHAR_CLASS = 1,     // Match character class using bitmap
    STATE_DOT = 2,            // Match any character except newline
    STATE_SPLIT = 3,          // Epsilon split to two states
    STATE_MATCH = 4,          // Accept state
    STATE_GROUP_START = 5,    // Capture group start
    STATE_GROUP_END = 6,      // Capture group end
    STATE_WORD_BOUNDARY = 7,  // \b
    STATE_NOT_WORD_BOUNDARY = 8, // \B
    STATE_LINE_START = 9,     // ^
    STATE_LINE_END = 10,      // $
    STATE_ANY = 11,           // . including newline
};

// Compiled regex state structure (matches Zig layout)
struct RegexState {
    uchar type;           // RegexStateType
    uchar flags;          // case_insensitive, negated, etc.
    ushort out;           // Next state index
    ushort out2;          // Second output for split states
    uchar literal_char;   // For STATE_LITERAL
    uchar group_idx;      // For GROUP_START/END
    uint bitmap_offset;   // Offset into bitmap buffer for STATE_CHAR_CLASS
};

// Compiled regex header (uploaded with pattern)
struct RegexHeader {
    uint num_states;
    uint start_state;
    uint num_groups;
    uint flags;           // anchored_start, anchored_end, case_insensitive
};

// Match result structure
struct RegexMatchResult {
    uint start;
    uint end;
    uint pattern_idx;
    uint flags;           // valid, etc.
};

// ----------------------------------------------------------------------------
// Character Class Bitmap Operations
// 256-bit bitmap stored as 8 x uint32
// ----------------------------------------------------------------------------

// Check if character is in bitmap (vectorized lookup)
inline bool bitmap_contains(constant uint* bitmap, uchar c) {
    uint word_idx = c >> 5;        // c / 32
    uint bit_idx = c & 31;         // c % 32
    return (bitmap[word_idx] & (1u << bit_idx)) != 0;
}

// Check if character is in bitmap (device memory)
inline bool bitmap_contains_device(device const uint* bitmap, uchar c) {
    uint word_idx = c >> 5;
    uint bit_idx = c & 31;
    return (bitmap[word_idx] & (1u << bit_idx)) != 0;
}

// Vectorized bitmap check for 4 characters
inline bool4 bitmap_contains4(constant uint* bitmap, uchar4 chars) {
    bool4 result;
    result[0] = bitmap_contains(bitmap, chars[0]);
    result[1] = bitmap_contains(bitmap, chars[1]);
    result[2] = bitmap_contains(bitmap, chars[2]);
    result[3] = bitmap_contains(bitmap, chars[3]);
    return result;
}

// ----------------------------------------------------------------------------
// Character Classification (for word boundaries)
// ----------------------------------------------------------------------------

inline bool regex_is_word_char(uchar c) {
    return (c >= 'a' && c <= 'z') ||
           (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') ||
           c == '_';
}

inline bool regex_is_word_boundary(device const uchar* text, uint text_len, uint pos) {
    bool before_is_word = (pos > 0) ? regex_is_word_char(text[pos - 1]) : false;
    bool after_is_word = (pos < text_len) ? regex_is_word_char(text[pos]) : false;
    return before_is_word != after_is_word;
}

// ----------------------------------------------------------------------------
// Lowercase Conversion
// ----------------------------------------------------------------------------

inline uchar regex_to_lower(uchar c) {
    return (c >= 'A' && c <= 'Z') ? c + 32 : c;
}

inline uchar4 regex_to_lower4(uchar4 c) {
    uchar4 lower = c + uchar4(32);
    return select(c, lower, (c >= uchar4('A')) && (c <= uchar4('Z')));
}

// ----------------------------------------------------------------------------
// NFA State Matching
// ----------------------------------------------------------------------------

// Check if a single state matches at position
inline bool regex_state_matches(
    constant RegexState* state,
    constant uint* bitmaps,
    device const uchar* text,
    uint text_len,
    uint pos,
    uchar c
) {
    bool case_insensitive = (state->flags & 0x01) != 0;

    switch ((RegexStateType)state->type) {
        case STATE_LITERAL: {
            uchar pattern_c = state->literal_char;
            if (case_insensitive) {
                return regex_to_lower(c) == regex_to_lower(pattern_c);
            }
            return c == pattern_c;
        }
        case STATE_CHAR_CLASS: {
            constant uint* bitmap = bitmaps + state->bitmap_offset;
            return bitmap_contains(bitmap, c);
        }
        case STATE_DOT:
            return c != '\n';
        case STATE_ANY:
            return true;
        case STATE_LINE_START:
            return pos == 0 || (pos > 0 && text[pos - 1] == '\n');
        case STATE_LINE_END:
            return pos == text_len || c == '\n';
        case STATE_WORD_BOUNDARY:
            return regex_is_word_boundary(text, text_len, pos);
        case STATE_NOT_WORD_BOUNDARY:
            return !regex_is_word_boundary(text, text_len, pos);
        default:
            return false;
    }
}

// ----------------------------------------------------------------------------
// NFA Execution (Thompson's Algorithm for GPU)
// Uses a fixed-size state set for parallel execution
// ----------------------------------------------------------------------------

// GPU-friendly state set using bitmask (supports up to 256 states)
struct StateSet {
    uint mask[8];  // 256 bits = 8 x 32-bit words
};

inline void state_set_clear(thread StateSet* set) {
    for (int i = 0; i < 8; i++) {
        set->mask[i] = 0;
    }
}

inline bool state_set_contains(thread StateSet* set, uint state_idx) {
    if (state_idx >= MAX_REGEX_STATES) return false;
    uint word = state_idx >> 5;
    uint bit = state_idx & 31;
    return (set->mask[word] & (1u << bit)) != 0;
}

inline void state_set_add(thread StateSet* set, uint state_idx) {
    if (state_idx >= MAX_REGEX_STATES) return;
    uint word = state_idx >> 5;
    uint bit = state_idx & 31;
    set->mask[word] |= (1u << bit);
}

inline bool state_set_empty(thread StateSet* set) {
    uint combined = 0;
    for (int i = 0; i < 8; i++) {
        combined |= set->mask[i];
    }
    return combined == 0;
}

// Add state following epsilon transitions (split, group markers, zero-width assertions)
inline void add_state_epsilon(
    thread StateSet* set,
    constant RegexState* states,
    constant uint* bitmaps,
    device const uchar* text,
    uint text_len,
    uint state_idx,
    uint pos
) {
    if (state_idx >= MAX_REGEX_STATES) return;
    if (state_set_contains(set, state_idx)) return;

    constant RegexState* state = &states[state_idx];

    switch ((RegexStateType)state->type) {
        case STATE_SPLIT:
            add_state_epsilon(set, states, bitmaps, text, text_len, state->out, pos);
            add_state_epsilon(set, states, bitmaps, text, text_len, state->out2, pos);
            break;
        case STATE_GROUP_START:
        case STATE_GROUP_END:
            add_state_epsilon(set, states, bitmaps, text, text_len, state->out, pos);
            break;
        case STATE_LINE_START:
            if (pos == 0 || (pos > 0 && text[pos - 1] == '\n')) {
                add_state_epsilon(set, states, bitmaps, text, text_len, state->out, pos);
            }
            break;
        case STATE_LINE_END:
            if (pos == text_len || (pos < text_len && text[pos] == '\n')) {
                add_state_epsilon(set, states, bitmaps, text, text_len, state->out, pos);
            }
            break;
        case STATE_WORD_BOUNDARY:
            if (regex_is_word_boundary(text, text_len, pos)) {
                add_state_epsilon(set, states, bitmaps, text, text_len, state->out, pos);
            }
            break;
        case STATE_NOT_WORD_BOUNDARY:
            if (!regex_is_word_boundary(text, text_len, pos)) {
                add_state_epsilon(set, states, bitmaps, text, text_len, state->out, pos);
            }
            break;
        default:
            state_set_add(set, state_idx);
            break;
    }
}

// Execute NFA at a specific starting position
// Returns true if pattern matches, with end position in out_end
inline bool regex_match_at(
    constant RegexHeader* header,
    constant RegexState* states,
    constant uint* bitmaps,
    device const uchar* text,
    uint text_len,
    uint start_pos,
    thread uint* out_end
) {
    StateSet current, next;
    state_set_clear(&current);
    state_set_clear(&next);

    // Initialize with start state (following epsilon transitions)
    add_state_epsilon(&current, states, bitmaps, text, text_len, header->start_state, start_pos);

    uint pos = start_pos;
    bool found_match = false;
    uint match_end = start_pos;

    // Check for immediate match (empty pattern or zero-width assertions at start)
    for (uint word = 0; word < 8; word++) {
        uint mask = current.mask[word];
        while (mask != 0) {
            uint bit = ctz(mask);
            uint state_idx = word * 32 + bit;
            mask &= mask - 1;

            if (states[state_idx].type == STATE_MATCH) {
                bool anchored_end = (header->flags & 0x02) != 0;
                if (!anchored_end || pos == text_len) {
                    found_match = true;
                    match_end = pos;
                }
            }
        }
    }

    // Process characters
    while (pos < text_len && !state_set_empty(&current)) {
        uchar c = text[pos];
        state_set_clear(&next);

        // For each active state, check if it matches current character
        for (uint word = 0; word < 8; word++) {
            uint mask = current.mask[word];
            while (mask != 0) {
                uint bit = ctz(mask);
                uint state_idx = word * 32 + bit;
                mask &= mask - 1;

                constant RegexState* state = &states[state_idx];
                if (regex_state_matches(state, bitmaps, text, text_len, pos, c)) {
                    if (state->out < header->num_states) {
                        add_state_epsilon(&next, states, bitmaps, text, text_len, state->out, pos + 1);
                    }
                }
            }
        }

        // Swap current and next
        current = next;
        pos++;

        // Check for match in new state set
        for (uint word = 0; word < 8; word++) {
            uint mask = current.mask[word];
            while (mask != 0) {
                uint bit = ctz(mask);
                uint state_idx = word * 32 + bit;
                mask &= mask - 1;

                if (states[state_idx].type == STATE_MATCH) {
                    bool anchored_end = (header->flags & 0x02) != 0;
                    if (!anchored_end || pos == text_len) {
                        found_match = true;
                        match_end = pos;
                    }
                }
            }
        }
    }

    *out_end = match_end;
    return found_match;
}

// Find first match in text starting at or after start_pos
inline bool regex_find(
    constant RegexHeader* header,
    constant RegexState* states,
    constant uint* bitmaps,
    device const uchar* text,
    uint text_len,
    uint start_pos,
    thread uint* out_start,
    thread uint* out_end
) {
    bool anchored_start = (header->flags & 0x01) != 0;

    if (anchored_start) {
        if (start_pos == 0) {
            *out_start = 0;
            return regex_match_at(header, states, bitmaps, text, text_len, 0, out_end);
        }
        return false;
    }

    // Try matching at each position
    for (uint pos = start_pos; pos <= text_len; pos++) {
        uint match_end;
        if (regex_match_at(header, states, bitmaps, text, text_len, pos, &match_end)) {
            *out_start = pos;
            *out_end = match_end;
            return true;
        }
    }

    return false;
}

#endif // REGEX_OPS_H
