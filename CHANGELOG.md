# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Negated pattern parsing: `!/root/` is now recognized as a pattern with `invert_match = true`, instead of being ignored
- Fixed `program_text` assignment bug where transpiler had incorrectly made it conditional on `program_text_allocated`, causing file arguments to be misinterpreted as additional program text
- Fixed stdin EOF handling: `error.EndOfStream` from `readStreaming()` is now treated as normal EOF
- Fixed evaluator pointer comparison crash on empty records (changed `&line[0] == &records.items[...][0]` to index-based `idx == len - 1`)
- Removed spurious `if (self.rules.len > 0)` wrapper that incorrectly made `endfile.deinit()` conditional
- Docker CI test commands now use `--entrypoint ""` to override `ENTRYPOINT ["gawk"]` during verification

## [0.6.0] - 2026-05-20

### Changed
- Migrated to Zig 0.16.0 API throughout (`std.process.Init`, `std.Io`, `std.Io.File`, `std.Io.Clock`)
- Docker base images upgraded from Alpine 3.19 to 3.21 for statx(2) compatibility
- Shared CI workflow (`e-jerk/.github`) updated to Zig 0.16.0
- zust added as proper `build.zig.zon` dependency
- vulkan-zig dependency updated to `master` for Zig 0.16 compat

### Fixed
- Transpiler-induced compilation errors: `ArrayListUnmanaged = .empty`, `ArrayList = .{}`, `DebugAllocator`, `trimStart`
- `statx: symbol not found` on Alpine Linux by upgrading base images
- gnu-tests-linux container upgraded from Alpine 3.19 to 3.21

### Added
- Zust memory-safety transpilation with memory-safety analyzer integration
- GNU compatibility tests: 32 tests covering pattern matching, field extraction, built-in functions, and variables

[0.6.0]: https://github.com/e-jerk/gawk/releases/tag/v0.6.0
