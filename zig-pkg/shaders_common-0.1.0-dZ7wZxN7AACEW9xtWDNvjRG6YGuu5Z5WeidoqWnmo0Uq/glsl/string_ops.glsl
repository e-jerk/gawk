// ============================================================================
// GPU String Operations - Common GLSL Functions
// Shared across grep, sed, awk, find utilities
// ============================================================================

#ifndef STRING_OPS_GLSL
#define STRING_OPS_GLSL

// ----------------------------------------------------------------------------
// Lowercase Conversion
// ----------------------------------------------------------------------------

// Scalar lowercase conversion
uint to_lower(uint c) {
    return (c >= 65u && c <= 90u) ? (c + 32u) : c;
}

// Vectorized lowercase for packed 4-byte word
// Converts each byte in the word to lowercase if it's A-Z
uint to_lower_word(uint word) {
    uint b0 = (word) & 0xFFu;
    uint b1 = (word >> 8u) & 0xFFu;
    uint b2 = (word >> 16u) & 0xFFu;
    uint b3 = (word >> 24u) & 0xFFu;

    uint m0 = (b0 >= 65u && b0 <= 90u) ? 0x20u : 0u;
    uint m1 = (b1 >= 65u && b1 <= 90u) ? 0x2000u : 0u;
    uint m2 = (b2 >= 65u && b2 <= 90u) ? 0x200000u : 0u;
    uint m3 = (b3 >= 65u && b3 <= 90u) ? 0x20000000u : 0u;

    return word + (m0 | m1 | m2 | m3);
}

// ----------------------------------------------------------------------------
// Character Matching
// ----------------------------------------------------------------------------

// Scalar character match with optional case insensitivity
bool char_match(uint pattern_c, uint text_c, bool case_insensitive) {
    if (case_insensitive) {
        return to_lower(pattern_c) == to_lower(text_c);
    }
    return pattern_c == text_c;
}

// Compare 4 bytes (one word) at once
bool match_word(uint text_word, uint pattern_word, bool case_insensitive) {
    if (case_insensitive) {
        text_word = to_lower_word(text_word);
        pattern_word = to_lower_word(pattern_word);
    }
    return text_word == pattern_word;
}

// Vectorized comparison using uvec4 - compare 16 bytes at once
bool match_uvec4(uvec4 text_words, uvec4 pattern_words, bool case_insensitive) {
    if (case_insensitive) {
        text_words.x = to_lower_word(text_words.x);
        text_words.y = to_lower_word(text_words.y);
        text_words.z = to_lower_word(text_words.z);
        text_words.w = to_lower_word(text_words.w);
        pattern_words.x = to_lower_word(pattern_words.x);
        pattern_words.y = to_lower_word(pattern_words.y);
        pattern_words.z = to_lower_word(pattern_words.z);
        pattern_words.w = to_lower_word(pattern_words.w);
    }
    return all(equal(text_words, pattern_words));
}

// ----------------------------------------------------------------------------
// Character Classification
// ----------------------------------------------------------------------------

// Check if character is a word character (alphanumeric or underscore)
bool is_word_char(uint c) {
    return (c >= 97u && c <= 122u) ||  // a-z
           (c >= 65u && c <= 90u) ||   // A-Z
           (c >= 48u && c <= 57u) ||   // 0-9
           c == 95u;                    // _
}

// Check if character is a newline
bool is_newline(uint c) {
    return c == 10u || c == 13u;  // \n or \r
}

#endif // STRING_OPS_GLSL
