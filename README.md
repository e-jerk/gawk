# GPU-Accelerated Gawk

A high-performance `awk` replacement that uses GPU acceleration via Metal (macOS) and Vulkan for blazing-fast text processing.

## Features

- **GPU-Accelerated Processing**: Parallel pattern matching and field extraction on compute shaders
- **SIMD-Optimized CPU**: Vectorized Boyer-Moore-Horspool with 16/32-byte operations
- **Auto-Selection**: Intelligent backend selection based on file size and pattern complexity
- **AWK Compatible**: Supports pattern matching, field splitting, and basic AWK operations

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

# Case-insensitive matching
gawk -i '/ERROR/' log.txt

# Force GPU backend
gawk --gpu '/pattern/' largefile.txt

# Verbose output
gawk -V '/pattern/' file.txt
```

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
| `--metal` | Force Metal backend (macOS only) |
| `--vulkan` | Force Vulkan backend |

## Architecture & Optimizations

### CPU Implementation (`src/cpu.zig`)

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

**SIMD Vector Operations**:
- `Vec16` and `Vec32` types (`@Vector(16, u8)`, `@Vector(32, u8)`)
- `findNextNewlineSIMD()`: 32-byte chunked newline search
- `toLowerVec16()`: Parallel lowercase conversion
- `SPACE_VEC32` and `TAB_VEC32` for whitespace detection

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

**Vulkan Shader (`src/shaders/awk.comp`)**:

- **uvec4 SIMD**: 16-byte vectorized comparison via `match_uvec4()`
- **Chunked Dispatch**: Balanced workload distribution across threads
- **Workgroup Size**: 256 threads (`local_size_x = 256`)
- **Packed Word Access**: Efficient unaligned 4-byte reads

### Processing Pipeline

```
processAwk(text, pattern, options):
  for each line in text:
    1. Find line boundaries (SIMD newline search)
    2. Search for pattern in line (Boyer-Moore-Horspool)
    3. If match found (or empty pattern):
       - Split line into fields (SIMD whitespace detection)
       - Record match metadata (line_start, match_pos, field_count)
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
```

### Auto-Selection

The `e_jerk_gpu` library considers:

- **Data Size**: GPU preferred for 1MB+ files
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
    line_num: u32,      // Line number (0-indexed)
    field_count: u32,   // Number of fields in line
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

| Operation | 50MB File | GPU Speedup |
|-----------|-----------|-------------|
| Pattern match | ~400 MB/s CPU | 2-4x |
| Field extraction | ~300 MB/s CPU | 2-3x |
| Case-insensitive | ~350 MB/s CPU | 3-4x |
| gsub replacement | ~250 MB/s CPU | 2-3x |

*Results measured on Apple M1 Max.*

## Requirements

- **macOS**: Metal support (built-in), optional MoltenVK for Vulkan
- **Linux**: Vulkan runtime (`libvulkan1`)
- **Build**: Zig 0.15.2+, glslc (Vulkan shader compiler)

## Building from Source

```bash
zig build -Doptimize=ReleaseFast

# Run tests
zig build test      # Unit tests
zig build smoke     # Integration tests
zig build bench     # Benchmarks
```

## License

Source code: [Unlicense](LICENSE) (public domain)
Binaries: GPL-3.0-or-later
