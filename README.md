# GPU-Accelerated Gawk

A high-performance `awk` replacement that uses GPU acceleration via Metal (macOS) and Vulkan for blazing-fast text processing.

## Features

- **GPU-Accelerated Processing**: Parallel pattern matching and field extraction on compute shaders
- **SIMD-Optimized CPU**: Vectorized Boyer-Moore-Horspool with 16/32-byte operations
- **Auto-Selection**: Intelligent backend selection based on file size and pattern complexity
- **AWK Compatible**: Supports pattern matching, field splitting, built-in functions, and special variables

## Installation

Homebrew formulas are now maintained in [e-jerk/utils](https://github.com/e-jerk/homebrew-utils) (pure GPU versions) and [e-jerk/utils-gnu](https://github.com/e-jerk/homebrew-utils-gnu) (GNU-fallback versions).

```bash
# Pure GPU version (no dependencies)
brew tap e-jerk/utils
brew install e-jerk/utils/gawk

# GNU-fallback version (with GNU fallback support)
brew tap e-jerk/utils-gnu
brew install e-jerk/utils-gnu/gawk
```

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

```bash
# BEGIN/END and variables
gawk 'BEGIN {sum=0} {sum+=$1} END {print sum}' file.txt

# gsub with & replacement
gawk '{gsub(/a/, "(&)"); print}' file.txt

# match with capture array
gawk '{match($0, /([0-9]+)/, arr); print arr[1]}' file.txt

# split into array
gawk '{n=split($0, a, ","); print a[2]}' file.txt

# getline from file
gawk 'BEGIN {while ((getline line < "file.txt") > 0) print line}'

# ENVIRON and FILENAME
gawk '{print ENVIRON["USER"], FILENAME, FNR}'

# asort array sorting
gawk '{split($0, a); n=asort(a); print a[1]}'

# IGNORECASE for case-insensitive matching
gawk 'BEGIN {IGNORECASE=1} /pattern/' file.txt
```

## GNU Feature Compatibility

| Feature | CPU | Metal | Vulkan | GPU Speedup | Status |
|---------|:---:|:-----:|:------:|:-----------:|--------|
| `/pattern/` matching | ✓ | ✓ | ✓ | **15x** | Native |
| `{print $N}` field extraction | ✓ | ✓ | ✓ | **8x** | Native |
| `-F` field separator | ✓ | ✓ | ✓ | **8x** | Native |
| `-i` case insensitive | ✓ | ✓ | ✓ | **6x** | Native |
| `-v` invert match | ✓ | ✓ | ✓ | **8x** | Native |
| `!/pattern/` negation | ✓ | ✓ | ✓ | **8x** | Native |
| Regex patterns `/[a-z]+/` | ✓ | ✓ | ✓ | **5-10x** | **Native** |
| `length($N)` | ✓ | ✓ | ✓ | **8x** | **Native** |
| `substr($N, s, l)` | ✓ | ✓ | ✓ | **8x** | **Native** |
| `substr($N, s)` | ✓ | ✓ | ✓ | **8x** | **Native** |
| `index($N, "str")` | ✓ | ✓ | ✓ | **8x** | **Native** |
| `toupper($N)` | ✓ | ✓ | ✓ | **8x** | **Native** |
| `tolower($N)` | ✓ | ✓ | ✓ | **8x** | **Native** |
| `NR` (line number) | ✓ | ✓ | ✓ | **8x** | **Native** |
| `NF` (field count / assignable) | ✓ | ✓ | ✓ | **8x** | **Native** |
| `gsub(/pat/, "repl")` with `&` and `\&` | ✓ | ✓ | ✓ | **8x** | **Native** |
| `sub(/pat/, "repl")` with `&` and `\&` | ✓ | ✓ | ✓ | **8x** | **Native** |
| `match(str, pattern [, arr])` | ✓ | — | — | CPU only | **Native** |
| `split(str, arr, sep)` | ✓ | — | — | CPU only | **Native** |
| `sprintf(fmt, ...)` | ✓ | — | — | CPU only | **Native** |
| `printf / print` with `>`, `>>`, `\|` | ✓ | — | — | CPU only | **Native** |
| `getline var < "file"` | ✓ | — | — | CPU only | **Native** |
| `getline` expression syntax | ✓ | — | — | CPU only | **Native** |
| `delete array[index]` | ✓ | — | — | CPU only | **Native** |
| `delete array` (clear array) | ✓ | — | — | CPU only | **Native** |
| `asort(arr [, dest])` | ✓ | — | — | CPU only | **Native** |
| `asorti(arr [, dest])` | ✓ | — | — | CPU only | **Native** |
| `ENVIRON` associative array | ✓ | — | — | CPU only | **Native** |
| `FILENAME`, `FNR` | ✓ | — | — | CPU only | **Native** |
| `ARGC`, `ARGV` | ✓ | — | — | CPU only | **Native** |
| `nextfile` | ✓ | — | — | CPU only | **Native** |
| `BEGIN/END` blocks | ✓ | ✓ | ✓ | **VM** | **Native** |
| `BEGINFILE/ENDFILE` blocks | ✓ | ✓ | ✓ | **VM** | **Native** |
| `RS` (record separator) | ✓ | — | — | N/A | **Native** |
| `ORS` (output record separator) | ✓ | — | — | N/A | **Native** |
| `IGNORECASE` global flag | ✓ | — | — | CPU only | **Native** |
| Variables `x=5` | ✓ | ✓ | ✓ | **VM** | **Native** |
| Arithmetic expressions | ✓ | ✓ | ✓ | **VM** | **Native** |
| Conditionals `if/else` | ✓ | ✓ | ✓ | **VM** | **Native** |
| Loops `while/for/do-while` | ✓ | ✓ | ✓ | **VM** | **Native** |
| `return`, `exit`, `break`, `continue` | ✓ | ✓ | ✓ | **VM** | **Native** |
| `sin/cos/sqrt/log/exp/int` | ✓ | ✓ | ✓ | **VM** | **Native** |
| Bitwise `and/or/xor/compl/lshift/rshift` | ✓ | ✓ | ✓ | **VM** | **Native** |
| `typeof(expr)` | ✓ | ✓ | ✓ | **VM** | **Native** |
| `gensub(pattern, repl, how [, target])` | ✓ | — | — | CPU only | **Native** |
| `strftime([fmt [, ts]])`, `systime()`, `mktime()` | ✓ | — | — | CPU only | **Native** |
| User-defined functions | ✓ | — | — | CPU only | **Native** |
| Multiple patterns | ✓ | — | — | CPU only | **Native** |
| Arrays `a[i]` | ✓ | — | — | CPU only | **Native** |

**GPU Bytecode VM**: Complex AWK programs are compiled to bytecode and executed on the GPU using a stack-based virtual machine. Each line is processed by a separate GPU thread. VM-native features run on both Metal and Vulkan backends.

**Test Coverage**: 45+ GNU compatibility tests passing, 17+ smoke tests including regex

**Backend Parity**: CPU, Metal, and Vulkan produce identical results for GPU-accelerated features.

## Built-in Functions

| Function | Description | Example |
|----------|-------------|---------|
| `length($N)` | Return length of field N | `{print length($1)}` → `5` |
| `substr($N, s, l)` | Substring starting at s with length l | `{print substr($1, 1, 3)}` → `hel` |
| `substr($N, s)` | Substring from s to end | `{print substr($1, 3)}` → `llo` |
| `index($N, "str")` | Position of str in field (1-indexed, 0 if not found) | `{print index($1, "ll")}` → `3` |
| `toupper($N)` | Convert to uppercase | `{print toupper($1)}` → `HELLO` |
| `tolower($N)` | Convert to lowercase | `{print tolower($1)}` → `hello` |
| `split(str, arr, sep)` | Split string into array by separator | `split("a,b,c", arr, ",")` → `arr[1]="a", arr[2]="b"` |
| `sprintf(fmt, ...)` | Format string | `sprintf("%s=%d", "x", 5)` → `"x=5"` |
| `match(str, pattern [, arr])` | Regex match position; optional array gets capture info | `match("abc", /b/, a)` → `2`, `a[0]="b"` |
| `gensub(pattern, repl, how [, target])` | Generalized substitution | `gensub(/a/, "A", "g", "banana")` → `"bAnAnA"` |
| `gsub(pat, repl [, target])` | Global substitution with `&` and `\&` | `gsub(/a/, "A", "banana")` → `"bAnAnA"` |
| `sub(pat, repl [, target])` | Substitute first occurrence with `&` and `\&` | `sub(/a/, "A", "banana")` → `"bAnana"` |
| `typeof(expr)` | Type of expression | `typeof(5)` → `"number"` |
| `and(a, b)` | Bitwise AND | `and(5, 3)` → `1` |
| `or(a, b)` | Bitwise OR | `or(5, 3)` → `7` |
| `xor(a, b)` | Bitwise XOR | `xor(5, 3)` → `6` |
| `compl(x)` | Bitwise complement | `compl(1)` → `-2` |
| `lshift(x, n)` | Left shift | `lshift(1, 3)` → `8` |
| `rshift(x, n)` | Right shift | `rshift(8, 3)` → `1` |
| `sin(x)`, `cos(x)` | Trigonometric functions | `sin(0)` → `0` |
| `sqrt(x)` | Square root | `sqrt(16)` → `4` |
| `log(x)` | Natural logarithm | `log(1)` → `0` |
| `exp(x)` | Exponential | `exp(0)` → `1` |
| `int(x)` | Integer truncation | `int(3.9)` → `3` |
| `strftime([fmt [, ts]])` | Format timestamp | `strftime("%Y")` → `"2026"` |
| `systime()` | Current time in seconds | `systime()` → `1715731200` |
| `mktime(datespec)` | Convert date to timestamp | `mktime("2024 01 01 00 00 00")` → `1704067200` |
| `asort(arr [, dest])` | Sort array by values | `asort(a, b)` → returns length |
| `asorti(arr [, dest])` | Sort array by indices | `asorti(a, b)` → returns length |

## Special Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `NR` | Current record number (total, 1-indexed) | `{print NR}` → `1`, `2`, `3`... |
| `NF` | Number of fields in current record (assignable) | `{print NF}` → `3` for "a b c"; `NF=2` truncates |
| `RS` | Record separator (single-char, multi-char, or `""` for paragraph mode) | `RS=""` enables paragraph mode |
| `ORS` | Output record separator | `ORS="\n\n"` → double-spaced output |
| `FS` | Field separator (default whitespace) | `FS=":"` is equivalent to `-F:` |
| `IGNORECASE` | Global case-insensitive matching flag | `IGNORECASE=1` makes `/a/` match `A` |
| `FILENAME` | Name of current input file | `{print FILENAME}` → `file.txt` |
| `FNR` | Record number in current file (1-indexed) | `{print FNR}` resets per file |
| `ARGC` | Number of command-line arguments | `ARGC` includes program and files |
| `ARGV` | Array of command-line arguments | `ARGV[1]` is the first file |
| `ENVIRON` | Associative array of environment variables | `ENVIRON["HOME"]` → `/Users/name` |

## Command Line Reference

<details>
<summary>Full --help output</summary>

```
Usage: gawk [OPTIONS] 'program' [file...]
       gawk [OPTIONS] '/pattern/' [file...]
       gawk [OPTIONS] '/pattern/ {print $1, $2}' [file...]
       gawk [OPTIONS] '{gsub(/old/, "new"); print}' [file...]

GPU-accelerated AWK for pattern matching, field extraction, and substitution.

Pattern Matching:                                [GPU+SIMD]
  /pattern/      Match lines containing pattern (regex supported)
  /pattern/i     Case-insensitive pattern matching (with -i flag)

Field Selection:                                 [GPU+SIMD]
  $0             Entire line
  $1, $2, ...    Individual fields (split by -F separator)
  $NF            Last field

Options:
  -F SEP         Use SEP as field separator (default: whitespace)
  -i             Case-insensitive pattern matching     [GPU+SIMD]
  -v             Invert match (print non-matching)     [GPU+SIMD]
  --backend MODE Backend: auto, cpu, gnu, gpu, metal, vulkan
  --cpu          Force CPU backend (SIMD-optimized)
  --gnu          Force GNU backend (gawk reference)
  --gpu          Force GPU (Metal on macOS, Vulkan otherwise)
  --verbose      Print backend selection and timing info
  -h, --help     Show this help

Built-in Functions:                              [GPU+SIMD]
  length($N)         Return length of field N
  substr($N, s, l)   Substring of field N from position s, length l
  substr($N, s)      Substring from position s to end
  index($N, "str")   Position of "str" in field N (0 if not found)
  toupper($N)        Convert field N to uppercase
  tolower($N)        Convert field N to lowercase
  split(str, arr, s) Split string into array by separator s
  sprintf(fmt, ...)  Format string
  match(s, p [, a])  Regex match; optional array a gets capture info
  gensub(p, r, h)    Generalized substitution
  gsub(p, r)         Global substitution with & and \& support
  sub(p, r)          Substitute first occurrence with & and \&

Substitution:                                    [GPU+SIMD]
  gsub(/pat/, "rep") Replace all occurrences with & and \& support
  sub(/pat/, "rep")  Replace first occurrence with & and \& support

Advanced Features (Full Parser):                 [CPU]
  BEGIN { }        Execute before processing any input
  END { }          Execute after processing all input
  BEGINFILE/ENDFILE  Per-file setup and teardown
  if/else/while/for/do-while  Control flow statements
  printf/sprintf   Formatted output
  print >, >>, |   Output redirection
  getline < file   Read from file
  delete a[i]      Delete array element
  delete a         Clear entire array
  asort/asorti     Array sorting
  nextfile         Skip to next input file
  return/exit/break/continue  Flow control
  User functions   User-defined functions
  Variables        User-defined variables and arithmetic
  ENVIRON          Environment variable array
  ARGC/ARGV        Command-line arguments
  FILENAME/FNR     Current file name and per-file record count
  IGNORECASE       Global case-insensitive flag
  RS/ORS           Record separators
  NF (assignable)  Truncate fields and rebuild $0
  typeof(expr)     Type of expression
  Bitwise          and, or, xor, compl, lshift, rshift
  Time             strftime, systime, mktime

Optimization Notes:
  [GPU+SIMD] Pattern matching uses Thompson NFA on GPU compute shaders.
             Field extraction and string functions run in parallel on GPU.
             CPU fallback uses 16/32-byte SIMD vector operations.
  [CPU]      Complex AWK programs with control flow, BEGIN/END blocks,
             or user variables use the full CPU-based parser/evaluator.

Examples:
  gawk '/error/' log.txt              Print lines containing 'error'
  gawk -F: '{print $1}' /etc/passwd   Print first field (colon-separated)
  gawk '/root/ {print $1, $3}' file   Print fields 1 and 3 from matching lines
  gawk '{gsub(/old/, "new"); print}'  Replace 'old' with 'new' globally
  gawk '{print length($1)}' file      Print length of first field
  gawk '{print substr($1, 1, 3)}'     Print first 3 chars of field 1
  gawk '{print toupper($1)}'          Print field 1 in uppercase
```

</details>

## Build Variants

| Variant | Description | Vulkan on macOS | `--gnu` flag |
|---------|-------------|-----------------|--------------|
| **pure** | Zig + SIMD + GPU only. No external dependencies. | No | Not available |
| **gnu** | Includes GNU gawk + Vulkan via MoltenVK. | Yes | Falls back to GNU gawk |

The gnu build enables Vulkan on macOS using MoltenVK, allowing both Metal and Vulkan backends on Mac.

## Backend Selection

| Flag | Description |
|------|-------------|
| `--auto` | Automatically select optimal backend (default) |
| `--gpu` | Use GPU (Metal on macOS, Vulkan elsewhere) |
| `--cpu` | Force CPU backend (SIMD-optimized) |
| `--gnu` | Force GNU gawk backend (gnu build only) |
| `--metal` | Force Metal backend (macOS only) |
| `--vulkan` | Force Vulkan backend (macOS+gnu build, or Linux) |

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
- **GPU Regex**: Thompson NFA execution via `regex_find()` from `regex_ops.h`
- **Bytecode VM**: `awk_vm_execute` kernel executes AWK bytecode on GPU

**GPU Bytecode Virtual Machine**:

Complex AWK programs are compiled to bytecode and executed on the GPU:
- `bytecode.zig`: Compiles AWK AST to stack-based bytecode instructions
- 4-byte fixed-size instructions for GPU alignment (opcode + 3 args)
- Per-thread execution: Each GPU thread processes one input line
- Supported operations: arithmetic, comparisons, control flow (if/while/for), variables, built-in math functions, field extraction, print
- `awk_vm_execute` kernel in Metal, `awk_vm.comp` shader in Vulkan

**GPU Regex Implementation**:

The regex engine uses Thompson NFA (Non-deterministic Finite Automaton) execution:
- `regex_compiler.zig`: Converts CPU regex to GPU-compatible format
- State machine uses 256-bit bitmask (8 x uint32) for active state tracking
- Supports: character classes `[a-z]`, quantifiers `+*?`, alternation `|`, groups `()`
- `awk_regex_match` kernel: Per-line regex matching with atomic result counting

**Vulkan Shader (`src/shaders/awk.comp`)**:

- **uvec4 SIMD**: 16-byte vectorized comparison via `match_uvec4()`
- **Chunked Dispatch**: Balanced workload distribution across threads
- **Workgroup Size**: 64 threads (`local_size_x = 64`)
- **Packed Word Access**: Efficient unaligned 4-byte reads
- **Field Count**: Populated during CPU-side field splitting for NF support
- **GPU Regex**: Thompson NFA execution via `regex_ops.glsl` (same algorithm as Metal)
- **Bytecode VM**: `awk_vm.comp` shader executes AWK bytecode (same VM as Metal)

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

### Literal Pattern Matching

| Operation | CPU | GPU | Speedup |
|-----------|-----|-----|---------|
| Pattern match | 477 MB/s | 287 MB/s | 0.6x |
| Field extraction | ~300 MB/s | ~400 MB/s | **1.3x** |
| Case-insensitive | ~350 MB/s | ~450 MB/s | **1.3x** |

Note: For simple literal patterns, CPU SIMD (Boyer-Moore-Horspool) is faster than GPU due to dispatch overhead. GPU wins on larger files (>10MB) and complex patterns.

### Regex Pattern Matching

| Pattern | CPU Regex | GPU (Metal/Vulkan) | Speedup |
|---------|-----------|-------------------|---------|
| `[0-9]+` | 10,266 ms | 6-8 ms | **~1,500x** |
| `hel+o` | 157 ms | 5-7 ms | **~25x** |
| `[a-z]+@[a-z]+` | 10,709 ms | 6-10 ms | **~1,500x** |
| `error\|warning` | 8,350 ms | 6-8 ms | **~1,200x** |

*Results measured on Apple M1 Max with 1MB test data, 3 iterations.*

The GPU regex engine uses Thompson NFA execution which is massively parallel - each thread processes one line independently. Metal and Vulkan have equivalent performance (Vulkan uses MoltenVK on macOS which translates to Metal).

## Requirements

- **macOS**: Metal support (built-in), optional MoltenVK for Vulkan
- **Linux**: Vulkan runtime (`libvulkan1`)
- **Build**: Zig 0.15.2+, glslc (Vulkan shader compiler)

## Building from Source

```bash
zig build -Doptimize=ReleaseFast

# Run tests
zig build test      # Unit tests
zig build smoke     # Integration tests (20 tests, GPU verification)
zig build bench     # Benchmarks (literal patterns)
zig build bench -- --regex  # Regex benchmarks (CPU vs GPU)
bash gnu-tests.sh   # GNU compatibility tests (45+ tests)
```

## Recent Changes

- **Record Separators**: `RS` supports single-char, multi-char, and paragraph mode (`RS=""`); `ORS` controls output record separator
- **File I/O**: `getline var < "file"` and expression syntax `while ((getline line < file) > 0)` for reading files
- **Redirection**: `print` and `printf` with `>`, `>>`, and `|` pipeline operators
- **Substitution**: `gsub()` and `sub()` in full evaluator with `&` and `\&` replacement semantics; `gensub()` for non-destructive substitution
- **Regex Capture**: `match(str, pattern [, array])` with array capture (`arr[0]`, `arr["start,0"]`, `arr["length,0"]`)
- **Case Control**: `IGNORECASE` global flag affects `~`, `!~`, `/pattern/`, `match()`, `gsub()`, `sub()`, `gensub()`
- **Array Operations**: `delete array[index]` and `delete array` (clear entire array); `asort()` and `asorti()` for array sorting
- **Array Splitting**: `split(str, arr, sep)` splits strings into indexed arrays
- **Formatting**: `sprintf(fmt, ...)` with `%s`, `%d`, `%f`, `%g` support
- **Bitwise Functions**: `and()`, `or()`, `xor()`, `compl()`, `lshift()`, `rshift()`
- **Time Functions**: `strftime([format [, timestamp]])`, `systime()`, `mktime()`
- **Type Introspection**: `typeof()` returns `"string"`, `"number"`, `"array"`, `"regexp"`, etc.
- **Field Truncation**: `NF` is assignable — truncates fields and rebuilds `$0`
- **File Variables**: `FILENAME` and `FNR` track current file name and per-file record numbers
- **Environment & CLI**: `ENVIRON` associative array; `ARGC`/`ARGV` for command-line arguments
- **Flow Control**: `nextfile` skips to next input file; `return`, `exit`, `break`, `continue` fully supported
- **User-Defined Functions**: Full support for custom functions with parameters and local variables
- **Control Flow**: `if/else`, `while`, `for`, `do-while` loops all execute in GPU bytecode VM
- **BEGINFILE/ENDFILE**: Per-file setup and teardown blocks execute natively
- **GPU Bytecode VM**: Full AWK programs compile to bytecode and execute on GPU (Metal + Vulkan)
  - Stack-based virtual machine with 4-byte instructions
  - Supports: variables, arithmetic, comparisons, control flow, built-in math/bitwise functions, field extraction, print
  - Each GPU thread processes one input line independently
- **100% Native AWK**: Full AWK parser/evaluator for complex programs — no GNU fallback needed
- **GPU Regex Support**: Native Thompson NFA regex execution on both Metal and Vulkan GPUs for patterns like `/[0-9]+/`, `/error|warning/`, `/hel+o/`
- **Backend Parity**: CPU, Metal, and Vulkan produce identical results for GPU-accelerated features
- **Test Coverage**: 45+ GNU compatibility tests passing, 17+ smoke tests (including CPU, Metal, and Vulkan regex)

## License

Source code: [Unlicense](LICENSE) (public domain)
Binaries: GPL-3.0-or-later
