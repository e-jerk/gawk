#ifndef STRING_OPS_H
#define STRING_OPS_H

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// GPU String Operations - Common Metal Functions
// Shared across grep, sed, awk, find utilities
// Optimized with uchar4 SIMD/vector operations (Metal's max vector width for uchar)
// ============================================================================

// ----------------------------------------------------------------------------
// Lowercase Conversion - Vectorized
// ----------------------------------------------------------------------------

// Scalar lowercase conversion
inline uchar to_lower(uchar c) {
    return (c >= 'A' && c <= 'Z') ? c + 32 : c;
}

// Vectorized lowercase conversion for 4 characters at once
inline uchar4 to_lower4(uchar4 c) {
    uchar4 lower = c + uchar4(32);
    return select(c, lower, (c >= uchar4('A')) && (c <= uchar4('Z')));
}

// ----------------------------------------------------------------------------
// Character Matching - Vectorized
// ----------------------------------------------------------------------------

// Scalar character match with optional case insensitivity
inline bool char_match(uchar pattern_c, uchar text_c, bool case_insensitive) {
    if (case_insensitive) {
        return to_lower(pattern_c) == to_lower(text_c);
    }
    return pattern_c == text_c;
}

// Vectorized 4-character comparison
inline bool match4(uchar4 pattern, uchar4 text, bool case_insensitive) {
    if (case_insensitive) {
        pattern = to_lower4(pattern);
        text = to_lower4(text);
    }
    return all(pattern == text);
}

// ----------------------------------------------------------------------------
// Character Classification - Vectorized
// ----------------------------------------------------------------------------

// Check if character is a word character (alphanumeric or underscore)
inline bool is_word_char(uchar c) {
    return (c >= 'a' && c <= 'z') ||
           (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') ||
           c == '_';
}

// Vectorized word character check for 4 chars
inline bool4 is_word_char4(uchar4 c) {
    bool4 lower = (c >= uchar4('a')) && (c <= uchar4('z'));
    bool4 upper = (c >= uchar4('A')) && (c <= uchar4('Z'));
    bool4 digit = (c >= uchar4('0')) && (c <= uchar4('9'));
    bool4 under = (c == uchar4('_'));
    return lower || upper || digit || under;
}

// Check if character is a newline
inline bool is_newline(uchar c) {
    return c == '\n' || c == '\r';
}

// Vectorized newline check for 4 chars
inline bool4 is_newline4(uchar4 c) {
    return (c == uchar4('\n')) || (c == uchar4('\r'));
}

// ----------------------------------------------------------------------------
// Pattern Matching - Vectorized with uchar4
// ----------------------------------------------------------------------------

// Vectorized pattern matching at a specific position
// Uses 4-byte chunks (Metal's max vector width for uchar)
inline bool match_at_position(
    device const uchar* text,
    uint text_len,
    uint pos,
    device const uchar* pattern,
    uint pattern_len,
    bool case_insensitive
) {
    if (pos + pattern_len > text_len) return false;

    device const uchar* text_ptr = text + pos;
    uint remaining = pattern_len;
    uint offset = 0;

    // Process 4 bytes at a time using uchar4
    while (remaining >= 4) {
        uchar4 p = uchar4(pattern[offset], pattern[offset+1], pattern[offset+2], pattern[offset+3]);
        uchar4 t = uchar4(text_ptr[offset], text_ptr[offset+1], text_ptr[offset+2], text_ptr[offset+3]);
        if (!match4(p, t, case_insensitive)) {
            return false;
        }
        offset += 4;
        remaining -= 4;
    }

    // Process remaining bytes one at a time
    while (remaining > 0) {
        if (!char_match(pattern[offset], text_ptr[offset], case_insensitive)) {
            return false;
        }
        offset++;
        remaining--;
    }

    return true;
}

// Check word boundaries around a match
inline bool check_word_boundary(
    device const uchar* text,
    uint text_len,
    uint match_start,
    uint match_end
) {
    if (match_start > 0 && is_word_char(text[match_start - 1])) return false;
    if (match_end < text_len && is_word_char(text[match_end])) return false;
    return true;
}

// ----------------------------------------------------------------------------
// Line Navigation - Vectorized
// ----------------------------------------------------------------------------

// Find the start of the line containing position pos
inline uint find_line_start(device const uchar* text, uint pos) {
    if (pos == 0) return 0;
    uint i = pos - 1;
    while (i > 0 && !is_newline(text[i])) i--;
    if (is_newline(text[i]) && i < pos) return i + 1;
    return i;
}

// Count newlines in a chunk using vectorized operations
inline uint count_newlines_vec(device const uchar* text, uint start, uint len) {
    uint count = 0;
    uint i = 0;

    // Process 4 bytes at a time using uchar4
    while (i + 4 <= len) {
        uchar4 chunk = uchar4(
            text[start + i], text[start + i + 1],
            text[start + i + 2], text[start + i + 3]
        );
        bool4 newlines = (chunk == uchar4('\n'));
        // Count matches in the vector
        if (newlines[0]) count++;
        if (newlines[1]) count++;
        if (newlines[2]) count++;
        if (newlines[3]) count++;
        i += 4;
    }

    // Process remaining bytes
    while (i < len) {
        if (text[start + i] == '\n') count++;
        i++;
    }

    return count;
}

// Find the start of the basename in a path (after last '/')
// Uses vectorized search with uchar4
inline uint find_basename_start(constant uchar* path, uint path_len) {
    uint start = 0;
    uint i = 0;

    // Process 4 bytes at a time
    while (i + 4 <= path_len) {
        uchar4 chars = uchar4(path[i], path[i+1], path[i+2], path[i+3]);
        bool4 slashes = (chars == uchar4('/'));
        // Check each position (later positions override earlier ones)
        if (slashes[3]) start = i + 4;
        else if (slashes[2]) start = i + 3;
        else if (slashes[1]) start = i + 2;
        else if (slashes[0]) start = i + 1;
        i += 4;
    }

    // Handle remaining bytes
    while (i < path_len) {
        if (path[i] == '/') {
            start = i + 1;
        }
        i++;
    }

    return start;
}

// Find the start of the basename using device pointer
inline uint find_basename_start_device(device const uchar* path, uint path_len) {
    uint start = 0;
    uint i = 0;

    // Process 4 bytes at a time
    while (i + 4 <= path_len) {
        uchar4 chars = uchar4(path[i], path[i+1], path[i+2], path[i+3]);
        bool4 slashes = (chars == uchar4('/'));
        // Check each position (later positions override earlier ones)
        if (slashes[3]) start = i + 4;
        else if (slashes[2]) start = i + 3;
        else if (slashes[1]) start = i + 2;
        else if (slashes[0]) start = i + 1;
        i += 4;
    }

    // Handle remaining bytes
    while (i < path_len) {
        if (path[i] == '/') {
            start = i + 1;
        }
        i++;
    }

    return start;
}

#endif // STRING_OPS_H
