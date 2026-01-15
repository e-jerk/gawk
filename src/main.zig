const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");
const cpu_gnu = @import("cpu_gnu");
const regex = @import("regex");

const AwkOptions = gpu.AwkOptions;
const isRegexPattern = regex.isRegexPattern;

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Parse arguments
    var options = AwkOptions{};
    var pattern: []const u8 = "";
    var action: []const u8 = "";
    var replacement: []const u8 = "";
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(allocator);
    var verbose = false;
    var backend_mode: BackendMode = .auto;
    var is_substitution = false;
    var builtin_call: ?BuiltinCall = null;
    var special_var: SpecialVar = .none;
    var allocated_fields: ?[]const u32 = null;
    defer if (allocated_fields) |f| allocator.free(f);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-F") and i + 1 < args.len) {
            i += 1;
            options.field_separator = args[i];
        } else if (std.mem.startsWith(u8, arg, "-F")) {
            options.field_separator = arg[2..];
        } else if (std.mem.eql(u8, arg, "-i")) {
            options.case_insensitive = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            options.invert_match = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--backend") and i + 1 < args.len) {
            i += 1;
            backend_mode = parseBackendMode(args[i]);
        } else if (std.mem.eql(u8, arg, "--cpu")) {
            backend_mode = .cpu;
        } else if (std.mem.eql(u8, arg, "--gnu")) {
            backend_mode = .cpu_gnu;
        } else if (std.mem.eql(u8, arg, "--gpu")) {
            backend_mode = .gpu;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return 0;
        } else if (arg[0] != '-') {
            // First non-option is pattern/action or file
            if (pattern.len == 0 and action.len == 0) {
                // Parse AWK program: /pattern/ or /pattern/ {action} or {action}
                const parsed = try parseAwkProgram(arg, allocator, &options);
                pattern = parsed.pattern;
                action = parsed.action;
                if (parsed.is_gsub) {
                    is_substitution = true;
                    replacement = parsed.replacement;
                }
                options.requested_fields = parsed.fields;
                if (parsed.fields.len > 0) {
                    allocated_fields = parsed.fields;
                }
                builtin_call = parsed.builtin;
                special_var = parsed.special_var;
            } else {
                try files.append(allocator, arg);
            }
        }
    }

    // Read input
    var text: []u8 = undefined;
    var text_allocator: std.mem.Allocator = allocator;

    if (files.items.len > 0) {
        // Read from files
        var total_size: usize = 0;
        for (files.items) |path| {
            const file = std.fs.cwd().openFile(path, .{}) catch |err| {
                std.debug.print("gawk: {s}: {}\n", .{ path, err });
                return 2;
            };
            defer file.close();
            const stat = try file.stat();
            total_size += stat.size;
        }

        text = try allocator.alloc(u8, total_size);
        var offset: usize = 0;
        for (files.items) |path| {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            const bytes_read = try file.readAll(text[offset..]);
            offset += bytes_read;
        }
    } else {
        // Read from stdin
        var stdin_list: std.ArrayListUnmanaged(u8) = .{};
        defer stdin_list.deinit(allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &buf) catch |err| {
                if (err == error.WouldBlock) continue;
                std.debug.print("gawk: error reading stdin: {}\n", .{err});
                return 2;
            };
            if (bytes_read == 0) break;
            try stdin_list.appendSlice(allocator, buf[0..bytes_read]);
        }
        text = try stdin_list.toOwnedSlice(allocator);
    }
    defer text_allocator.free(text);

    // Handle substitution mode (gsub)
    if (is_substitution) {
        // Check if pattern contains regex metacharacters
        const use_regex = isRegexPattern(pattern);

        if (use_regex) {
            const substitutions = try cpu.findSubstitutionsRegex(text, pattern, options, allocator);
            defer allocator.free(substitutions);

            const result_text = try cpu.applySubstitutionsRegex(text, substitutions, replacement, allocator);
            defer allocator.free(result_text);

            _ = std.posix.write(std.posix.STDOUT_FILENO, result_text) catch {};
        } else {
            const substitutions = try cpu.findSubstitutions(text, pattern, options, allocator);
            defer allocator.free(substitutions);

            const result_text = try cpu.applySubstitutions(text, substitutions, pattern.len, replacement, allocator);
            defer allocator.free(result_text);

            _ = std.posix.write(std.posix.STDOUT_FILENO, result_text) catch {};
        }
        return 0;
    }

    // Check if pattern contains regex metacharacters
    const use_regex = pattern.len > 0 and isRegexPattern(pattern);

    // Select backend (GPU backends don't support regex yet, fall back to CPU)
    const backend = if (use_regex) gpu.Backend.cpu else selectBackend(backend_mode, text.len, verbose);

    // Process AWK
    var result = switch (backend) {
        .metal => blk: {
            if (build_options.is_macos) {
                const searcher = gpu.metal.MetalAwk.init(allocator) catch |err| {
                    if (verbose) std.debug.print("Metal init failed: {}, falling back to CPU\n", .{err});
                    break :blk try cpu.processAwk(text, pattern, options, allocator);
                };
                defer searcher.deinit();
                break :blk searcher.processAwk(text, pattern, options, allocator) catch |err| {
                    if (verbose) std.debug.print("Metal failed: {}, falling back to CPU\n", .{err});
                    break :blk try cpu.processAwk(text, pattern, options, allocator);
                };
            } else {
                break :blk try cpu.processAwk(text, pattern, options, allocator);
            }
        },
        .vulkan => blk: {
            const searcher = gpu.vulkan.VulkanAwk.init(allocator) catch |err| {
                if (verbose) std.debug.print("Vulkan init failed: {}, falling back to CPU\n", .{err});
                break :blk try cpu.processAwk(text, pattern, options, allocator);
            };
            defer searcher.deinit();
            break :blk searcher.processAwk(text, pattern, options, allocator) catch |err| {
                if (verbose) std.debug.print("Vulkan failed: {}, falling back to CPU\n", .{err});
                break :blk try cpu.processAwk(text, pattern, options, allocator);
            };
        },
        .cpu, .cuda, .opencl => if (backend_mode == .cpu_gnu)
            try cpu_gnu.processAwk(text, pattern, options, allocator)
        else if (use_regex)
            try cpu.processAwkRegex(text, pattern, options, allocator)
        else
            try cpu.processAwk(text, pattern, options, allocator),
    };
    defer result.deinit();

    // Output results
    for (result.matches, 0..) |match, match_idx| {
        const line = text[match.line_start..match.line_end];

        // Handle special variables NR and NF
        if (special_var != .none) {
            var buf: [32]u8 = undefined;
            const value = switch (special_var) {
                .nr => match.line_num + 1, // AWK line numbers are 1-indexed
                .nf => match.field_count,
                .none => unreachable,
            };
            const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "0";
            _ = std.posix.write(std.posix.STDOUT_FILENO, str) catch {};
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
        } else if (builtin_call) |bc| {
            // Apply built-in function
            // Find the specified field
            var field_text: []const u8 = line; // Default to whole line if $0
            if (bc.field_num > 0) {
                for (result.fields) |field| {
                    if (field.line_idx == @as(u32, @intCast(match_idx)) and
                        field.field_idx == bc.field_num)
                    {
                        field_text = line[field.start_offset..field.end_offset];
                        break;
                    }
                }
            }

            // Apply the function
            switch (bc.func) {
                .length => {
                    var buf: [32]u8 = undefined;
                    const len_str = std.fmt.bufPrint(&buf, "{d}", .{field_text.len}) catch "0";
                    _ = std.posix.write(std.posix.STDOUT_FILENO, len_str) catch {};
                },
                .substr => {
                    // AWK substr is 1-indexed
                    const start: usize = if (bc.arg1 > 0) @intCast(bc.arg1 - 1) else 0;
                    if (start < field_text.len) {
                        const max_len = field_text.len - start;
                        const len: usize = if (bc.arg2 >= 0) @min(@as(usize, @intCast(bc.arg2)), max_len) else max_len;
                        _ = std.posix.write(std.posix.STDOUT_FILENO, field_text[start..][0..len]) catch {};
                    }
                },
                .index_fn => {
                    var buf: [32]u8 = undefined;
                    const pos: usize = if (std.mem.indexOf(u8, field_text, bc.string_arg)) |p| p + 1 else 0;
                    const pos_str = std.fmt.bufPrint(&buf, "{d}", .{pos}) catch "0";
                    _ = std.posix.write(std.posix.STDOUT_FILENO, pos_str) catch {};
                },
                .toupper => {
                    var upper_buf: [4096]u8 = undefined;
                    const out_len = @min(field_text.len, upper_buf.len);
                    for (field_text[0..out_len], 0..) |c, idx| {
                        upper_buf[idx] = if (c >= 'a' and c <= 'z') c - 32 else c;
                    }
                    _ = std.posix.write(std.posix.STDOUT_FILENO, upper_buf[0..out_len]) catch {};
                },
                .tolower => {
                    var lower_buf: [4096]u8 = undefined;
                    const out_len = @min(field_text.len, lower_buf.len);
                    for (field_text[0..out_len], 0..) |c, idx| {
                        lower_buf[idx] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                    }
                    _ = std.posix.write(std.posix.STDOUT_FILENO, lower_buf[0..out_len]) catch {};
                },
                .none => {
                    _ = std.posix.write(std.posix.STDOUT_FILENO, field_text) catch {};
                },
            }
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
        } else if (options.requested_fields.len > 0) {
            // Print specific fields
            var first = true;
            for (options.requested_fields) |field_num| {
                // Find field in result
                for (result.fields) |field| {
                    if (field.line_idx == @as(u32, @intCast(match_idx)) and
                        field.field_idx == field_num)
                    {
                        if (!first) _ = std.posix.write(std.posix.STDOUT_FILENO, options.output_field_separator) catch {};
                        first = false;
                        const field_text = line[field.start_offset..field.end_offset];
                        _ = std.posix.write(std.posix.STDOUT_FILENO, field_text) catch {};
                        break;
                    }
                }
            }
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
        } else {
            // Print whole line
            _ = std.posix.write(std.posix.STDOUT_FILENO, line) catch {};
            _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
        }
    }

    // AWK returns 0 on success regardless of whether patterns matched
    return 0;
}

const BackendMode = enum {
    auto,
    gpu,
    cpu,
    cpu_gnu, // GNU gawk reference implementation
    metal,
    vulkan,
};

fn parseBackendMode(s: []const u8) BackendMode {
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "gpu")) return .gpu;
    if (std.mem.eql(u8, s, "cpu")) return .cpu;
    if (std.mem.eql(u8, s, "gnu")) return .cpu_gnu;
    if (std.mem.eql(u8, s, "metal")) return .metal;
    if (std.mem.eql(u8, s, "vulkan")) return .vulkan;
    return .auto;
}

fn selectBackend(mode: BackendMode, text_len: usize, verbose: bool) gpu.Backend {
    _ = verbose;
    switch (mode) {
        .cpu, .cpu_gnu => return .cpu,
        .metal => return .metal,
        .vulkan => return .vulkan,
        .gpu => {
            if (build_options.is_macos) return .metal;
            return .vulkan;
        },
        .auto => {
            if (text_len < gpu.MIN_GPU_SIZE) return .cpu;
            if (build_options.is_macos) return .metal;
            return .vulkan;
        },
    }
}

/// Built-in function types
const BuiltinFunction = enum {
    none,
    length, // length($N)
    substr, // substr($N, start, len) or substr($N, start)
    index_fn, // index($N, "str")
    toupper, // toupper($N)
    tolower, // tolower($N)
};

/// Built-in function call info
const BuiltinCall = struct {
    func: BuiltinFunction,
    field_num: u32, // Which field ($1, $2, etc.)
    arg1: i32 = 0, // For substr: start position (1-indexed)
    arg2: i32 = -1, // For substr: length (-1 means to end)
    string_arg: []const u8 = "", // For index: search string
};

/// Special variable types
const SpecialVar = enum {
    none,
    nr, // NR - line number
    nf, // NF - number of fields
};

const ParsedProgram = struct {
    pattern: []const u8,
    action: []const u8,
    fields: []const u32,
    is_gsub: bool,
    replacement: []const u8,
    builtin: ?BuiltinCall = null, // Built-in function to apply
    special_var: SpecialVar = .none, // Special variable to print
};

fn parseAwkProgram(program: []const u8, allocator: std.mem.Allocator, options: *AwkOptions) !ParsedProgram {
    var result = ParsedProgram{
        .pattern = "",
        .action = "",
        .fields = &.{},
        .is_gsub = false,
        .replacement = "",
    };

    var i: usize = 0;

    // Skip whitespace
    while (i < program.len and (program[i] == ' ' or program[i] == '\t')) i += 1;

    // Check for inverted pattern: !/pattern/
    if (i < program.len and program[i] == '!' and i + 1 < program.len and program[i + 1] == '/') {
        options.invert_match = true;
        i += 1; // Skip '!'
    }

    // Check for pattern: /pattern/
    if (i < program.len and program[i] == '/') {
        i += 1;
        const pattern_start = i;
        while (i < program.len and program[i] != '/') i += 1;
        result.pattern = program[pattern_start..i];
        if (i < program.len) i += 1; // Skip closing /
    }

    // Skip whitespace
    while (i < program.len and (program[i] == ' ' or program[i] == '\t')) i += 1;

    // Check for action: {action}
    if (i < program.len and program[i] == '{') {
        i += 1;
        const action_start = i;
        var brace_depth: usize = 1;
        while (i < program.len and brace_depth > 0) {
            if (program[i] == '{') brace_depth += 1;
            if (program[i] == '}') brace_depth -= 1;
            i += 1;
        }
        result.action = program[action_start .. i - 1];

        // Parse action for print fields or gsub
        const action = result.action;

        // Check for gsub
        if (std.mem.indexOf(u8, action, "gsub(")) |gsub_start| {
            result.is_gsub = true;

            // Parse gsub(/pattern/, "replacement")
            var j = gsub_start + 5; // After "gsub("

            // Skip to pattern
            while (j < action.len and action[j] != '/') j += 1;
            if (j < action.len) j += 1;
            const pat_start = j;
            while (j < action.len and action[j] != '/') j += 1;
            result.pattern = action[pat_start..j];
            if (j < action.len) j += 1;

            // Skip to replacement
            while (j < action.len and action[j] != '"') j += 1;
            if (j < action.len) j += 1;
            const repl_start = j;
            while (j < action.len and action[j] != '"') j += 1;
            result.replacement = action[repl_start..j];
        }

        // Check for special variables NR and NF
        if (std.mem.indexOf(u8, action, "print")) |_| {
            // Check for NR (line number)
            if (std.mem.indexOf(u8, action, "NR") != null) {
                result.special_var = .nr;
            } else if (std.mem.indexOf(u8, action, "NF") != null) {
                result.special_var = .nf;
            }
        }

        // Check for built-in functions: length($N), substr($N, ...), index($N, ...), toupper($N), tolower($N)
        if (std.mem.indexOf(u8, action, "length(")) |len_start| {
            result.builtin = parseBuiltinCall(action[len_start..], .length);
        } else if (std.mem.indexOf(u8, action, "substr(")) |sub_start| {
            result.builtin = parseBuiltinCall(action[sub_start..], .substr);
        } else if (std.mem.indexOf(u8, action, "index(")) |idx_start| {
            result.builtin = parseBuiltinCall(action[idx_start..], .index_fn);
        } else if (std.mem.indexOf(u8, action, "toupper(")) |up_start| {
            result.builtin = parseBuiltinCall(action[up_start..], .toupper);
        } else if (std.mem.indexOf(u8, action, "tolower(")) |lo_start| {
            result.builtin = parseBuiltinCall(action[lo_start..], .tolower);
        }

        // Check for print $N (if no builtin function and no special var)
        if (result.builtin == null and result.special_var == .none and std.mem.indexOf(u8, action, "print") != null) {
            var fields_list: std.ArrayListUnmanaged(u32) = .{};

            var j: usize = 0;
            while (j < action.len) {
                if (action[j] == '$' and j + 1 < action.len) {
                    j += 1;
                    var num: u32 = 0;
                    while (j < action.len and action[j] >= '0' and action[j] <= '9') {
                        num = num * 10 + (action[j] - '0');
                        j += 1;
                    }
                    if (num > 0) {
                        try fields_list.append(allocator, num);
                    }
                } else {
                    j += 1;
                }
            }

            result.fields = try fields_list.toOwnedSlice(allocator);
        }
    }

    return result;
}

/// Parse a built-in function call from action text
fn parseBuiltinCall(text: []const u8, func_type: BuiltinFunction) ?BuiltinCall {
    var result = BuiltinCall{
        .func = func_type,
        .field_num = 0,
    };

    // Find opening parenthesis
    var i: usize = 0;
    while (i < text.len and text[i] != '(') i += 1;
    if (i >= text.len) return null;
    i += 1;

    // Skip whitespace
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;

    // Parse $N for field reference
    if (i < text.len and text[i] == '$') {
        i += 1;
        var field_num: u32 = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') {
            field_num = field_num * 10 + (text[i] - '0');
            i += 1;
        }
        result.field_num = field_num;
    } else {
        return null; // Expected $N
    }

    // For substr and index, parse additional arguments
    if (func_type == .substr) {
        // Skip to comma
        while (i < text.len and text[i] != ',') i += 1;
        if (i >= text.len) return null;
        i += 1;

        // Skip whitespace
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;

        // Parse start position
        var start: i32 = 0;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') {
            start = start * 10 + @as(i32, @intCast(text[i] - '0'));
            i += 1;
        }
        result.arg1 = start;

        // Check for optional length argument
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i < text.len and text[i] == ',') {
            i += 1;
            while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
            var len: i32 = 0;
            while (i < text.len and text[i] >= '0' and text[i] <= '9') {
                len = len * 10 + @as(i32, @intCast(text[i] - '0'));
                i += 1;
            }
            result.arg2 = len;
        }
    } else if (func_type == .index_fn) {
        // Skip to comma
        while (i < text.len and text[i] != ',') i += 1;
        if (i >= text.len) return null;
        i += 1;

        // Skip whitespace
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;

        // Parse quoted string
        if (i < text.len and text[i] == '"') {
            i += 1;
            const str_start = i;
            while (i < text.len and text[i] != '"') i += 1;
            result.string_arg = text[str_start..i];
        }
    }

    return result;
}

fn printHelp() void {
    const help =
        \\Usage: gawk [OPTIONS] 'program' [file...]
        \\       gawk [OPTIONS] '/pattern/' [file...]
        \\       gawk [OPTIONS] '/pattern/ {print $1, $2}' [file...]
        \\       gawk [OPTIONS] '{gsub(/old/, "new"); print}' [file...]
        \\
        \\GPU-accelerated AWK for pattern matching, field extraction, and substitution.
        \\
        \\Options:
        \\  -F SEP         Use SEP as field separator (default: whitespace)
        \\  -i             Case-insensitive pattern matching
        \\  -v             Invert match (print non-matching lines)
        \\  --backend MODE Backend: auto, cpu, gnu, gpu, metal, vulkan (default: auto)
        \\  --cpu          Force CPU backend
        \\  --gnu          Force GNU backend (reference implementation)
        \\  --gpu          Force GPU backend (Metal on macOS, Vulkan otherwise)
        \\  --verbose      Print backend selection and timing info
        \\  -h, --help     Show this help
        \\
        \\Built-in Functions:
        \\  length($N)         Return length of field N
        \\  substr($N, s, l)   Return substring of field N starting at s with length l
        \\  index($N, "str")   Return position of "str" in field N (0 if not found)
        \\  toupper($N)        Convert field N to uppercase
        \\  tolower($N)        Convert field N to lowercase
        \\
        \\Examples:
        \\  gawk '/error/' log.txt              Print lines containing 'error'
        \\  gawk -F: '{print $1}' /etc/passwd   Print first field (colon-separated)
        \\  gawk '/root/ {print $1, $3}' file   Print fields 1 and 3 from matching lines
        \\  gawk '{gsub(/old/, "new"); print}'  Replace 'old' with 'new' globally
        \\  gawk '{print length($1)}' file      Print length of first field
        \\  gawk '{print substr($1, 1, 3)}'     Print first 3 chars of field 1
        \\  gawk '{print toupper($1)}'          Print field 1 in uppercase
        \\
    ;
    std.debug.print("{s}", .{help});
}
