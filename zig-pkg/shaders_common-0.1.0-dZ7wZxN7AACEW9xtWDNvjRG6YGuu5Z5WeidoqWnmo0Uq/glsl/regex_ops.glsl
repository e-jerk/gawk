// ============================================================================
// GPU Regex Operations - Common GLSL Functions
// Shared across grep, sed, awk utilities
// Implements Thompson NFA execution with vectorized character class matching
// ============================================================================

#ifndef REGEX_OPS_GLSL
#define REGEX_OPS_GLSL

// Maximum states supported per regex pattern
#define MAX_REGEX_STATES 256
#define MAX_CAPTURE_GROUPS 16

// State set using 8 x 32-bit words (256 bits)
#define STATE_SET_WORDS 8

// ----------------------------------------------------------------------------
// NFA State Types (must match Zig StateType enum)
// ----------------------------------------------------------------------------
#define STATE_LITERAL           0u
#define STATE_CHAR_CLASS        1u
#define STATE_DOT               2u
#define STATE_SPLIT             3u
#define STATE_MATCH             4u
#define STATE_GROUP_START       5u
#define STATE_GROUP_END         6u
#define STATE_WORD_BOUNDARY     7u
#define STATE_NOT_WORD_BOUNDARY 8u
#define STATE_LINE_START        9u
#define STATE_LINE_END          10u
#define STATE_ANY               11u

// Flag bits in header.flags
#define FLAG_ANCHORED_START 0x01u
#define FLAG_ANCHORED_END   0x02u
#define FLAG_CASE_INSENSITIVE 0x04u

// Flag bits in state.flags
#define STATE_FLAG_CASE_INSENSITIVE 0x01u
#define STATE_FLAG_NEGATED 0x02u

// Invalid state index
#define STATE_NONE 0xFFFFu

// ----------------------------------------------------------------------------
// Character Classification
// ----------------------------------------------------------------------------

bool regex_is_word_char(uint c) {
    return (c >= 97u && c <= 122u) ||   // a-z
           (c >= 65u && c <= 90u) ||    // A-Z
           (c >= 48u && c <= 57u) ||    // 0-9
           c == 95u;                     // _
}

uint regex_to_lower(uint c) {
    return (c >= 65u && c <= 90u) ? (c + 32u) : c;
}

// ----------------------------------------------------------------------------
// State Set Operations (256-bit bitmask)
// These operate on a uint[8] array that must be declared in the calling code
// ----------------------------------------------------------------------------

#define STATE_SET_CLEAR(set) \
    set[0] = 0u; set[1] = 0u; set[2] = 0u; set[3] = 0u; \
    set[4] = 0u; set[5] = 0u; set[6] = 0u; set[7] = 0u

#define STATE_SET_CONTAINS(set, idx) \
    (((idx) < MAX_REGEX_STATES) && ((set[(idx) >> 5u] & (1u << ((idx) & 31u))) != 0u))

#define STATE_SET_ADD(set, idx) \
    if ((idx) < MAX_REGEX_STATES) { set[(idx) >> 5u] |= (1u << ((idx) & 31u)); }

#define STATE_SET_EMPTY(set) \
    ((set[0] | set[1] | set[2] | set[3] | set[4] | set[5] | set[6] | set[7]) == 0u)

#define STATE_SET_COPY(dest, src) \
    dest[0] = src[0]; dest[1] = src[1]; dest[2] = src[2]; dest[3] = src[3]; \
    dest[4] = src[4]; dest[5] = src[5]; dest[6] = src[6]; dest[7] = src[7]

// ----------------------------------------------------------------------------
// Helper functions for reading packed state data
// States are packed as: [type:8][flags:8][out:16][out2:16][literal:8][group_idx:8][bitmap_offset:32]
// Total: 12 bytes = 3 x uint32
// ----------------------------------------------------------------------------

uint get_state_type(uint state_word0) {
    return state_word0 & 0xFFu;
}

uint get_state_flags(uint state_word0) {
    return (state_word0 >> 8u) & 0xFFu;
}

uint get_state_out(uint state_word0) {
    return (state_word0 >> 16u) & 0xFFFFu;
}

uint get_state_out2(uint state_word1) {
    return state_word1 & 0xFFFFu;
}

uint get_state_literal(uint state_word1) {
    return (state_word1 >> 16u) & 0xFFu;
}

uint get_state_group_idx(uint state_word1) {
    return (state_word1 >> 24u) & 0xFFu;
}

uint get_state_bitmap_offset(uint state_word2) {
    return state_word2;
}

// Get character at position from packed text buffer (4 bytes per uint)
uint get_char_at_pos(uint text_word, uint byte_offset) {
    return (text_word >> (byte_offset * 8u)) & 0xFFu;
}

// ----------------------------------------------------------------------------
// Zero-width assertion checking
// These need the text buffer bound as a storage buffer in the shader
// ----------------------------------------------------------------------------

// Check if position satisfies LINE_START (^ anchor)
// text_buf: buffer containing packed text
// text_len: length of text in bytes
// pos: position to check
bool check_line_start(uint prev_char, uint pos) {
    if (pos == 0u) return true;
    return prev_char == 10u;  // \n
}

// Check if position satisfies LINE_END ($ anchor)
bool check_line_end(uint curr_char, uint pos, uint text_len) {
    if (pos == text_len) return true;
    return curr_char == 10u;  // \n
}

// Check word boundary
// prev_is_word: is the character before pos a word character
// curr_is_word: is the character at pos a word character
bool check_word_boundary(bool prev_is_word, bool curr_is_word) {
    return prev_is_word != curr_is_word;
}

// ----------------------------------------------------------------------------
// NFA State Matching
// Returns true if state matches character c at position pos
// ----------------------------------------------------------------------------

bool regex_state_matches_char(
    uint state_type,
    uint state_flags,
    uint state_literal,
    uint bitmap_word,  // Pre-fetched bitmap word for c
    uint bitmap_bit,   // Pre-computed bit position
    uint c
) {
    bool case_insensitive = (state_flags & STATE_FLAG_CASE_INSENSITIVE) != 0u;

    if (state_type == STATE_LITERAL) {
        uint pattern_c = state_literal;
        if (case_insensitive) {
            return regex_to_lower(c) == regex_to_lower(pattern_c);
        }
        return c == pattern_c;
    }
    else if (state_type == STATE_CHAR_CLASS) {
        return (bitmap_word & (1u << bitmap_bit)) != 0u;
    }
    else if (state_type == STATE_DOT) {
        return c != 10u;  // \n
    }
    else if (state_type == STATE_ANY) {
        return true;
    }

    return false;
}

// ----------------------------------------------------------------------------
// Regex Result Structure
// ----------------------------------------------------------------------------

struct RegexResult {
    uint match_start;
    uint match_end;
    bool found;
};

// ----------------------------------------------------------------------------
// Usage Notes:
//
// To use this library in a compute shader:
// 1. Declare storage buffers for text, states, and bitmaps
// 2. Declare state set arrays as local variables: uint current[8], next[8];
// 3. Use STATE_SET_* macros to manipulate state sets
// 4. Use get_state_* functions to decode packed state data
// 5. Implement the NFA execution loop calling regex_state_matches_char
//
// Example skeleton:
//
// void main() {
//     uint current[8], next[8];
//     STATE_SET_CLEAR(current);
//     STATE_SET_ADD(current, start_state);
//
//     for (uint pos = 0; pos < text_len; pos++) {
//         STATE_SET_CLEAR(next);
//         uint c = get_char_at_pos(text[pos >> 2], pos & 3u);
//
//         for (uint word = 0; word < 8; word++) {
//             uint mask = current[word];
//             while (mask != 0u) {
//                 uint bit = findLSB(mask);
//                 uint state_idx = word * 32u + bit;
//                 mask &= mask - 1u;
//
//                 // Process state at state_idx
//                 uint base = state_idx * 3u;
//                 uint word0 = states[base];
//                 uint word1 = states[base + 1u];
//                 uint word2 = states[base + 2u];
//
//                 uint state_type = get_state_type(word0);
//                 // ... match and transition logic
//             }
//         }
//
//         STATE_SET_COPY(current, next);
//     }
// }
// ----------------------------------------------------------------------------

#endif // REGEX_OPS_GLSL
