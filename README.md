# GPU-Accelerated Gawk

A high-performance `awk` replacement that uses GPU acceleration via Metal (macOS) and Vulkan for blazing-fast text processing.

## Features

- **GPU-Accelerated Processing**: Parallel pattern matching and field extraction on compute shaders
- **SIMD-Optimized CPU**: Vectorized Boyer-Moore-Horspool with 16/32-byte operations
- **Auto-Selection**: Intelligent backend selection based on file size and pattern complexity
- **AWK Compatible**: Supports pattern matching, field splitting, built-in functions, and special variables

## Installation

Available via Homebrew. See the homebrew-utils repository for installation instructions.

## Usage

```bash
# Print lines matching pattern
gawk '/pattern/' file.txt

# Print specific field
gawk '{print $2}' file.txt

# Pattern with action
gawk '/error/ {print $0}' log.txt

# Custom field separator
gawk -F: '{print $1}' /etc/passwd

# Multiple fields
gawk -F: '{print $1, $3}' /etc/passwd

# Case-insensitive matching
gawk -i '/ERROR/' log.txt

# Invert match (print non-matching lines)
gawk '!/debug/' log.txt

# Built-in functions
gawk '{print length($1)}' file.txt           # String length
gawk '{print substr($1, 1, 3)}' file.txt     # Substring
gawk '{print substr($1, 3)}' file.txt        # Substring to end
gawk '{print index($1, "ll")}' file.txt      # Find substring position
gawk '{print toupper($1)}' file.txt          # Convert to uppercase
gawk '{print tolower($1)}' file.txt          # Convert to lowercase

# Special variables
gawk '{print NR}' file.txt                   # Line number
gawk '{print NF}' file.txt                   # Number of fields
gawk '/pattern/ {print NR}' file.txt         # Line numbers of matches
gawk -F: '{print NF}' file.txt               # Fields with custom separator

# Global substitution
gawk '{gsub(/old/, "new"); print}' file.txt

# Force GPU backend
gawk --gpu '/pattern/' largefile.txt

# Verbose output
gawk -V '/pattern/' file.txt
```

## GNU Feature Compatibility

| Feature | CPU-Optimized | GNU Backend | Metal | Vulkan | Status |
|---------|:-------------:|:-----------:|:-----:|:------:|--------|
| `/pattern/` matching | ✓ | ✓ | ✓ | ✓ | Native |
| `{print $N}` field extraction | ✓ | ✓ | ✓ | ✓ | Native |
| `-F` field separator | ✓ | ✓ | ✓ | ✓ | Native |
| `-i` case insensitive | ✓ | ✓ | ✓ | ✓ | Native |
| `-v` invert match | ✓ | ✓ | ✓ | ✓ | Native |
| `!/pattern/` negation | ✓ | ✓ | ✓ | ✓ | Native |
| `gsub(/pat/, "repl")` | ✓ | ✓ | — | — | Native (CPU) |
| `length($N)` | ✓ | ✓ | ✓ | ✓ | **Native** |
| `substr($N, s, l)` | ✓ | ✓ | ✓ | ✓ | **Native** |
| `index($N, "str")` | ✓ | ✓ | ✓ | ✓ | **Native** |
| `toupper($N)` | ✓ | ✓ | ✓ | ✓ | **Native** |
| `tolower($N)` | ✓ | ✓ | ✓ | ✓ | **Native** |
| `NR` (line number) | ✓ | ✓ | ✓ | ✓ | **Native** |
| `NF` (field count) | ✓ | ✓ | ✓ | ✓ | **Native** |
| Regex patterns | — | ✓ | — | — | GNU fallback |
| `BEGIN/END` blocks | — | ✓ | — | — | GNU fallback |
| Variables | — | ✓ | — | — | GNU fallback |
| User-defined functions | — | ✓ | — | — | GNU fallback |
| Multiple patterns | — | ✓ | — | — | GNU fallback |
| Arithmetic expressions | — | ✓ | — | — | GNU fallback |
| Conditionals | — | ✓ | — | — | GNU fallback |

**Test Coverage**: 32/32 GNU compatibility tests passing

**Backend Parity**: CPU, Metal, and Vulkan produce identical results for all features.

## Built-in Functions

| Function | Description | Example |
|----------|-------------|---------|
| `length($N)` | Return length of field N | `{print length($1)}` → `5` |
| `substr($N, s, l)` | Substring starting at s with length l | `{print substr($1, 1, 3)}` → `hel` |
| `substr($N, s)` | Substring from s to end | `{print substr($1, 3)}` → `llo` |
| `index($N, "str")` | Position of str in field (1-indexed, 0 if not found) | `{print index($1, "ll")}` → `3` |
| `toupper($N)` | Convert to uppercase | `{print toupper($1)}` → `HELLO` |
| `tolower($N)` | Convert to lowercase | `{print tolower($1)}` → `hello` |

## Special Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `NR` | Current line number (1-indexed) | `{print NR}` → `1`, `2`, `3`... |
| `NF` | Number of fields in current line | `{print NF}` → `3` for "a b c" |

## Options

| Flag | Description |
|------|-------------|
| `-F, --field-separator` | Set field separator |
| `-i, --ignore-case` | Case-insensitive pattern matching |
| `-v, --invert-match` | Print non-matching lines |
| `-V, --verbose` | Show timing and backend info |

## Backend Selection

| Flag | Description |
|------|-------------|
| `--auto` | Automatically select optimal backend (default) |
| `--gpu` | Use GPU (Metal on macOS, Vulkan elsewhere) |
| `--cpu` | Force CPU backend |
| `--gnu` | Force GNU gawk backend |
| `--metal` | Force Metal backend (macOS only) |
| `--vulkan` | Force Vulkan backend |

## Architecture & Optimizations

### CPU Implementation (`src/cpu_optimized.zig`)

The CPU backend provides SIMD-optimized AWK processing:

**Pattern Matching**:
- `processAwk()`: Main processing function combining search and field extraction
- `searchLineSIMD()`: Boyer-Moore-Horspool search within each line
- `matchAtPositionSIMD()`: 16-byte vectorized pattern comparison
- Pre-computed 256-entry skip table for O(n/m) average case

**Field Splitting**:
- `splitFieldsSIMD()`: SIMD-accelerated field extraction
- 32-byte chunked whitespace detection using `Vec32`
- Supports both whitespace (default) and custom separators
- Tracks field boundaries as `(start_offset, end_offset)` pairs
- Returns `field_count` for NF variable support

**SIMD Vector Operations**:
- `Vec16` and `Vec32` types (`@Vector(16, u8)`, `@Vector(32, u8)`)
- `findNextNewlineSIMD()`: 32-byte chunked newline search
- `toLowerVec16()`: Parallel lowercase conversion
- `SPACE_VEC32` and `TAB_VEC32` for whitespace detection

**Built-in Functions**:
- `BuiltinFunction` enum: `length`, `substr`, `index_fn`, `toupper`, `tolower`
- `BuiltinCall` struct captures function type, field number, and arguments
- `parseBuiltinCall()`: Extracts function calls from AWK actions
- Applied during output phase for efficient processing

**Special Variables**:
- `SpecialVar` enum: `nr`, `nf`
- Line number tracking during `processAwk()`
- Field count returned from `splitFieldsSIMD()`

**Substitution (gsub)**:
- `findSubstitutions()`: Finds all non-overlapping pattern matches
- `applySubstitutions()`: Builds result with SIMD-friendly `@memcpy`
- Handles length changes from replacement strings

### GPU Implementation

**Metal Shader (`src/shaders/awk.metal`)**:

- **Chunked Processing**: Each thread handles a range of text positions
- **uchar4 SIMD**: 4-byte vectorized pattern matching via `match_at_position()`
- **Field Extraction**: Parallel whitespace detection for field boundaries
- **Atomic Counters**: Thread-safe match and field counting
- **Field Count**: Populated during CPU-side field splitting for NF support

**Vulkan Shader (`src/shaders/awk.comp`)**:

- **uvec4 SIMD**: 16-byte vectorized comparison via `match_uvec4()`
- **Chunked Dispatch**: Balanced workload distribution across threads
- **Workgroup Size**: 64 threads (`local_size_x = 64`)
- **Packed Word Access**: Efficient unaligned 4-byte reads
- **Field Count**: Populated during CPU-side field splitting for NF support

### Processing Pipeline

```
processAwk(text, pattern, options):
  for each line in text:
    1. Find line boundaries (SIMD newline search)
    2. Search for pattern in line (Boyer-Moore-Horspool)
    3. If match found (or empty pattern):
       - Split line into fields (SIMD whitespace detection)
       - Record match metadata (line_start, match_pos, line_num, field_count)
    4. Apply invert_match if set

  return matches[] and fields[]
```

### Field Splitting Algorithm

```
splitFieldsSIMD(line, separator):
  if whitespace_separator and line.len >= 32:
    // Process 32 bytes at a time
    for each 32-byte chunk:
      spaces = chunk == SPACE_VEC32
      tabs = chunk == TAB_VEC32
      whitespace = spaces | tabs

      if any(whitespace):
        process byte-by-byte within chunk
      else:
        mark entire chunk as in-field

  // Handle remaining bytes
  for each remaining byte:
    track field start/end transitions

  return field_count
```

### Auto-Selection

The `e_jerk_gpu` library considers:

- **Data Size**: GPU preferred for 128KB+ files
- **Field Complexity**: More fields increase GPU advantage
- **Hardware Tier**: Adjusts thresholds based on GPU performance score

## Data Structures

```zig
// Match result for each matching line
AwkMatchResult = struct {
    line_start: u32,    // Start of line in text
    line_end: u32,      // End of line in text
    match_start: u32,   // Pattern match position within line
    match_end: u32,     // End of pattern match
    line_num: u32,      // Line number (0-indexed, output as 1-indexed)
    field_count: u32,   // Number of fields in line (for NF)
};

// Field boundary information
FieldInfo = struct {
    line_idx: u32,      // Index into matches array
    field_idx: u32,     // Field number (1-indexed like AWK)
    start_offset: u32,  // Start within line
    end_offset: u32,    // End within line
};
```

## Performance

| Operation | CPU | GPU | Speedup |
|-----------|-----|-----|---------|
| Pattern match | 357 MB/s | 476 MB/s | **1.3x** |
| Field extraction | ~300 MB/s | ~400 MB/s | **1.3x** |
| Case-insensitive | ~350 MB/s | ~450 MB/s | **1.3x** |

*Results measured on Apple M1 Max with 10MB test files.*

Note: GPU speedup for gawk is modest because the workload involves complex field splitting that currently runs on CPU. Pattern matching benefits from GPU parallelism, while field extraction is optimized for CPU SIMD.

## Requirements

- **macOS**: Metal support (built-in), optional MoltenVK for Vulkan
- **Linux**: Vulkan runtime (`libvulkan1`)
- **Build**: Zig 0.15.2+, glslc (Vulkan shader compiler)

## Building from Source

```bash
zig build -Doptimize=ReleaseFast

# Run tests
zig build test      # Unit tests
zig build smoke     # Integration tests (GPU verification)
zig build bench     # Benchmarks
bash gnu-tests.sh   # GNU compatibility tests (32 tests)
```

## Recent Changes

- **Built-in Functions**: Native `length()`, `substr()`, `index()`, `toupper()`, `tolower()`
- **Special Variables**: Native `NR` (line number) and `NF` (field count) support
- **Backend Parity**: CPU, Metal, and Vulkan now produce identical results
- **Field Count Fix**: GPU backends properly track `field_count` for NF variable
- **Test Coverage**: 32 GNU compatibility tests passing

## License

Source code: [Unlicense](LICENSE) (public domain)
Binaries: GPL-3.0-or-later
