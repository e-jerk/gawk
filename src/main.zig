const std = @import("std");
const safe = @import("safe");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");
const cpu_gnu = @import("cpu_gnu");
const regex = @import("regex");
const parser = @import("parser.zig");
const evaluator = @import("evaluator.zig");
const bytecode = @import("bytecode.zig");
const Value = @import("value.zig").Value;
const ast = @import("ast.zig");

const AwkOptions = gpu.AwkOptions;
const isRegexPattern = regex.isRegexPattern;

pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    while (args_iter.next()) |arg| {
        try args.append(allocator, arg);
    }
    const args_slice = args.items;

    // Parse arguments
    var options = AwkOptions{};
    var pattern: []const u8 = "";
    var action: []const u8 = "";
    var replacement: []const u8 = "";
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);
    var verbose = false;
    var backend_mode: BackendMode = .auto;
    var is_substitution = false;
    var substitution_global = true; // true = gsub, false = sub
    var builtin_call: ?BuiltinCall = null;
    var special_var: SpecialVar = .none;
    var allocated_fields: ?[]const u32 = null;
    // safe-transpile: free removed (memory owned by safe type);
    var program_text: []const u8 = ""; // Original AWK program for full parsing
    var program_text_allocated = false;
    // safe-transpile: free removed (memory owned by safe type);
    var variables: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer {
        var var_it = variables.iterator();
        while (var_it.next()) |_| {
            // safe-transpile: free removed (memory owned by safe type);
        }
        variables.deinit(allocator);
    }

    var i: usize = 1;
    while (i < args_slice.len) : (i += 1) {
        const arg = args_slice[i];

        if (safe.SimdUtils.eql(arg, "-F") and i + 1 < args_slice.len) {
            i += 1;
            options.field_separator = args_slice[i];
        } else if (std.mem.startsWith(u8, arg, "-F")) {
            options.field_separator = arg[2..];
        } else if (safe.SimdUtils.eql(arg, "-i")) {
            options.case_insensitive = true;
        } else if (safe.SimdUtils.eql(arg, "--invert-match")) {
            options.invert_match = true;
        } else if (safe.SimdUtils.eql(arg, "-v") and i + 1 < args_slice.len) {
            i += 1;
            const assign = args_slice[i];
            // zust: use safe.String or safe.GuardedSlice for slice operations
            if (std.mem.indexOf(u8, assign, "=")) |eq_pos| {
                const var_name = assign[0..eq_pos];
                const var_val = assign[eq_pos + 1 ..];
                const name_copy = try allocator.dupe(u8, var_name);
                const val_copy = try allocator.dupe(u8, var_val);
                try variables.put(allocator, name_copy, val_copy);
            } else {
                std.debug.print("gawk: invalid -v assignment: {s}\n", .{assign});
                return 2;
            }
        } else if (safe.SimdUtils.eql(arg, "-f") and i + 1 < args_slice.len) {
            i += 1;
            const file = std.Io.Dir.cwd().openFile(init.io, args_slice[i], .{}) catch |err| {
                std.debug.print("gawk: {s}: {}\n", .{ args_slice[i], err });
                return 2;
            };
            defer file.close(init.io);
            const content = readFileToEndAlloc(file, init.io, allocator, 1024 * 1024) catch |err| {
                std.debug.print("gawk: {s}: {}\n", .{ args_slice[i], err });
                return 2;
            };
            // safe-transpile: free removed (memory owned by safe type);
            // Concatenate to program_text
            if (program_text.len > 0) {
                const combined = try std.mem.concat(allocator, u8, &.{ program_text, "\n", content });
                if (program_text_allocated) {
                    // safe-transpile: free removed (memory owned by safe type);
                }
                program_text = combined;
                program_text_allocated = true;
            } else {
                program_text = try allocator.dupe(u8, content);
                program_text_allocated = true;
            }
        } else if (safe.SimdUtils.eql(arg, "-e") and i + 1 < args_slice.len) {
            i += 1;
            if (program_text.len > 0) {
                const combined = try std.mem.concat(allocator, u8, &.{ program_text, "\n", args_slice[i] });
                if (program_text_allocated) {
                    // safe-transpile: free removed (memory owned by safe type);
                }
                program_text = combined;
                program_text_allocated = true;
            } else {
                program_text = try allocator.dupe(u8, args_slice[i]);
                program_text_allocated = true;
            }
        } else if (safe.SimdUtils.eql(arg, "--assign") and i + 1 < args_slice.len) {
            // --assign is an alias for -v
            i += 1;
            const assign = args_slice[i];
            // zust: use safe.String or safe.GuardedSlice for slice operations
            if (std.mem.indexOf(u8, assign, "=")) |eq_pos| {
                const var_name = assign[0..eq_pos];
                const var_val = assign[eq_pos + 1 ..];
                const name_copy = try allocator.dupe(u8, var_name);
                const val_copy = try allocator.dupe(u8, var_val);
                try variables.put(allocator, name_copy, val_copy);
            } else {
                std.debug.print("gawk: invalid --assign assignment: {s}\n", .{assign});
                return 2;
            }
        } else if (safe.SimdUtils.eql(arg, "--version")) {
            std.Io.File.stdout().writeStreamingAll(init.io, "gawk (e-jerk GPU-accelerated) 1.0\n") catch {};
            return 0;
        } else if (safe.SimdUtils.eql(arg, "--traditional") or safe.SimdUtils.eql(arg, "-c")) {
            options.traditional_mode = true;
        } else if (safe.SimdUtils.eql(arg, "--posix") or safe.SimdUtils.eql(arg, "-P")) {
            options.posix_mode = true;
        } else if (safe.SimdUtils.eql(arg, "--lint")) {
            options.lint_mode = true;
        } else if (safe.SimdUtils.eql(arg, "--dump-variables")) {
            options.dump_variables = true;
        } else if (safe.SimdUtils.eql(arg, "--profile")) {
            options.profile_mode = true;
        } else if (safe.SimdUtils.eql(arg, "-W") and i + 1 < args_slice.len) {
            i += 1;
            const w_arg = args_slice[i];
            if (safe.SimdUtils.eql(w_arg, "traditional")) {
                options.traditional_mode = true;
            } else if (safe.SimdUtils.eql(w_arg, "posix")) {
                options.posix_mode = true;
            } else if (safe.SimdUtils.eql(w_arg, "lint")) {
                options.lint_mode = true;
            } else if (safe.SimdUtils.eql(w_arg, "dump-variables")) {
                options.dump_variables = true;
            } else if (safe.SimdUtils.eql(w_arg, "profile")) {
                options.profile_mode = true;
            } else if (safe.SimdUtils.eql(w_arg, "version")) {
                std.Io.File.stdout().writeStreamingAll(init.io, "gawk (e-jerk GPU-accelerated) 1.0\n") catch {};
                return 0;
            } else if (std.mem.startsWith(u8, w_arg, "dump-variables=")) {
                options.dump_variables = true;
            } else if (std.mem.startsWith(u8, w_arg, "profile=")) {
                options.profile_mode = true;
            } else {
                std.debug.print("gawk: unknown -W option: {s}\n", .{w_arg});
                return 2;
            }
        } else if (safe.SimdUtils.eql(arg, "--verbose")) {
            verbose = true;
        } else if (safe.SimdUtils.eql(arg, "--backend") and i + 1 < args_slice.len) {
            i += 1;
            backend_mode = parseBackendMode(args_slice[i]);
        } else if (safe.SimdUtils.eql(arg, "--cpu")) {
            backend_mode = .cpu;
        } else if (safe.SimdUtils.eql(arg, "--gnu")) {
            backend_mode = .cpu_gnu;
        } else if (safe.SimdUtils.eql(arg, "--gpu")) {
            backend_mode = .gpu;
        } else if (safe.SimdUtils.eql(arg, "--metal")) {
            backend_mode = .metal;
        } else if (safe.SimdUtils.eql(arg, "--vulkan")) {
            backend_mode = .vulkan;
        } else if (safe.SimdUtils.eql(arg, "-h") or safe.SimdUtils.eql(arg, "--help")) {
            printHelp();
            return 0;
        } else if (arg[0] != '-') {
            // First non-option is pattern/action or file
            // If program already came from -f/-e, treat all non-options as files
            if (program_text.len > 0) {
                try files.append(allocator, arg);
            } else if (pattern.len == 0 and action.len == 0) {
                if (program_text_allocated) {
                    // safe-transpile: free removed (memory owned by safe type);
                }
                program_text = arg; // Save original program for full parsing
                program_text_allocated = false;
                // Parse AWK program: /pattern/ or /pattern/ {action} or {action}
                const parsed = try parseAwkProgram(arg, allocator, &options);
                pattern = parsed.pattern;
                action = parsed.action;
                if (parsed.is_gsub or parsed.is_sub) {
                    is_substitution = true;
                    substitution_global = parsed.is_gsub;
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

    // If program came from -f/-e and hasn't been parsed yet, parse it now
    if (program_text.len > 0 and pattern.len == 0 and action.len == 0) {
        const parsed = try parseAwkProgram(program_text, allocator, &options);
        pattern = parsed.pattern;
        action = parsed.action;
        if (parsed.is_gsub or parsed.is_sub) {
            is_substitution = true;
            substitution_global = parsed.is_gsub;
            replacement = parsed.replacement;
        }
        options.requested_fields = parsed.fields;
        if (parsed.fields.len > 0) {
            allocated_fields = parsed.fields;
        }
        builtin_call = parsed.builtin;
        special_var = parsed.special_var;
    }

    // Read input
    var text: []u8 = &[_]u8{};

    if (files.items.len > 0) {
        // Read from files
        var total_size: usize = 0;
        for (files.items) |path| {
            const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch |err| {
                std.debug.print("gawk: {s}: {}\n", .{ path, err });
                return 2;
            };
            defer file.close(init.io);
            const stat = try file.stat(init.io);
            total_size += stat.size;
        }

        text = try allocator.alloc(u8, total_size);
        var offset: usize = 0;
        for (files.items) |path| {
            const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
            defer file.close(init.io);
            var bytes_read: usize = 0;
            while (bytes_read < total_size - offset) {
                const n = try file.readStreaming(init.io, &.{text[offset + bytes_read..]});
                if (n == 0) break;
                bytes_read += n;
            }
            offset += bytes_read;
        }
    } else {
        // Read from stdin
        var stdin_list: std.ArrayListUnmanaged(u8) = .empty;
        defer stdin_list.deinit(allocator);
        var buf: [4096]u8 = undefined;
        var __zust_loop_counter: u64 = 0;
        while (true) {
            __zust_loop_counter += 1;
            if (__zust_loop_counter > 1_000_000) return error.InfiniteLoop;

            const bytes_read = std.Io.File.stdin().readStreaming(init.io, &.{&buf}) catch |err| {
                if (err == error.WouldBlock) continue;
                if (err == error.EndOfStream) break;
                std.debug.print("gawk: error reading stdin: {}\n", .{err});
                return 2;
            };
            if (bytes_read == 0) break;
            try stdin_list.appendSlice(allocator, buf[0..bytes_read]);
        }
        text = try stdin_list.toOwnedSlice(allocator);
    }
    // safe-transpile: free removed (memory owned by safe type);

    // Check if program needs full parser/evaluator for complex AWK features
    if (needsFullParser(program_text)) {
        // Try GPU bytecode VM first for full feature parity
        if (executeFullAwkGpu(program_text, text, options, backend_mode, verbose, allocator)) |output| {
            // safe-transpile: free removed (memory owned by safe type);
            std.Io.File.stdout().writeStreamingAll(init.io, output) catch {};
            return 0;
        } else |_| {
            // Fall back to CPU evaluator with per-file processing
            if (verbose) std.debug.print("GPU bytecode VM unavailable, using CPU evaluator\n", .{});
            // Parse program once
            var p = parser.Parser.init(program_text, allocator);
            var program = p.parse() catch {
                std.debug.print("gawk: parse error\n", .{});
                return 1;
            };
            defer program.deinit();
            var eval = evaluator.Evaluator.init(allocator, &program.functions, init.io, init.environ_map);
            defer eval.deinit();
            if (!safe.SimdUtils.eql(options.field_separator, " \t")) {
                eval.field_separator = options.field_separator;
            }
            var var_it = variables.iterator();
            while (var_it.next()) |entry| {
                const val = Value.initString(entry.value_ptr.*);
                try eval.variables.put(allocator, entry.key_ptr.*, val);
            }

            // Set up ARGC and ARGV
            const argc_val = @as(f64, @floatFromInt(files.items.len + 1));
            try eval.variables.put(allocator, "ARGC", Value.initNumber(argc_val));
            var argv_array = std.StringHashMapUnmanaged(Value){};
            try argv_array.put(allocator, "0", Value.initString("gawk"));
            // safe-transpile: for with index access requires manual review
            for (files.items, 0..) |path, idx| {
                const key = try std.fmt.allocPrint(allocator, "{d}", .{idx + 1});
                try argv_array.put(allocator, key, Value.initString(path));
            }
            try eval.arrays.put(allocator, "ARGV", argv_array);

            if (files.items.len > 0) {
                // safe-transpile: for with index access requires manual review
                for (files.items, 0..) |path, file_idx| {
                    const file_text = readFileToString(allocator, path, init.io) catch |err| {
                        std.debug.print("gawk: {s}: {}\n", .{ path, err });
                        continue;
                    };
                    // safe-transpile: free removed (memory owned by safe type);
                    const is_last = file_idx == files.items.len - 1;
                    const output = eval.execute(&program, file_text, path, is_last) catch |err| {
                        std.debug.print("gawk: error executing program: {}\n", .{err});
                        return 1;
                    };
                    // safe-transpile: free removed (memory owned by safe type);
                    std.Io.File.stdout().writeStreamingAll(init.io, output) catch {};
                    // Check if nextfile was requested; if so, continue to next file
                    // (eval.execute already breaks on next_file, so we just continue)
                }
            } else {
                const output = eval.execute(&program, text, null, true) catch |err| {
                    std.debug.print("gawk: error executing program: {}\n", .{err});
                    return 1;
                };
                // safe-transpile: free removed (memory owned by safe type);
                std.Io.File.stdout().writeStreamingAll(init.io, output) catch {};
            }
            return 0;
        }
    }

    // Handle substitution mode (sub / gsub)
    if (is_substitution) {
        // Check if pattern contains regex metacharacters
        const use_regex = isRegexPattern(pattern);

        if (use_regex) {
            const substitutions = try cpu.findSubstitutionsRegex(text, pattern, options, allocator);
            // safe-transpile: free removed (memory owned by safe type);

            const subs_to_apply = if (substitution_global) substitutions else if (substitutions.len > 0) substitutions[0..1] else substitutions;
            const result_text = try cpu.applySubstitutionsRegex(text, subs_to_apply, replacement, allocator);
            // safe-transpile: free removed (memory owned by safe type);

            std.Io.File.stdout().writeStreamingAll(init.io, result_text) catch {};
        } else {
            const substitutions = try cpu.findSubstitutions(text, pattern, options, allocator);
            // safe-transpile: free removed (memory owned by safe type);

            const subs_to_apply = if (substitution_global) substitutions else if (substitutions.len > 0) substitutions[0..1] else substitutions;
            const result_text = try cpu.applySubstitutions(text, subs_to_apply, pattern.len, replacement, allocator);
            // safe-transpile: free removed (memory owned by safe type);

            std.Io.File.stdout().writeStreamingAll(init.io, result_text) catch {};
        }
        return 0;
    }

    // Check if pattern contains regex metacharacters
    const use_regex = pattern.len > 0 and isRegexPattern(pattern);

    // Select backend - GPU now supports regex via NFA state machine
    const backend = selectBackend(backend_mode, text.len, verbose);

    // Process AWK
    var result = switch (backend) {
        .metal => blk: {
            if (build_options.is_macos) {
                const searcher = gpu.metal.MetalAwk.init(allocator) catch |err| {
                    if (verbose) std.debug.print("Metal init failed: {}, falling back to CPU\n", .{err});
                    break :blk if (use_regex)
                        try cpu.processAwkRegex(text, pattern, options, allocator)
                    else
                        try cpu.processAwk(text, pattern, options, allocator);
                };
                defer searcher.deinit();

                // Use GPU regex if pattern has metacharacters
                if (use_regex) {
                    break :blk searcher.processAwkRegex(text, pattern, options, allocator) catch |err| {
                        if (verbose) std.debug.print("Metal regex failed: {}, falling back to CPU\n", .{err});
                        break :blk try cpu.processAwkRegex(text, pattern, options, allocator);
                    };
                } else {
                    break :blk searcher.processAwk(text, pattern, options, allocator) catch |err| {
                        if (verbose) std.debug.print("Metal failed: {}, falling back to CPU\n", .{err});
                        break :blk try cpu.processAwk(text, pattern, options, allocator);
                    };
                }
            } else {
                break :blk if (use_regex)
                    try cpu.processAwkRegex(text, pattern, options, allocator)
                else
                    try cpu.processAwk(text, pattern, options, allocator);
            }
        },
        .vulkan => blk: {
            const searcher = gpu.vulkan.VulkanAwk.init(allocator) catch |err| {
                if (verbose) std.debug.print("Vulkan init failed: {}, falling back to CPU\n", .{err});
                break :blk if (use_regex)
                    try cpu.processAwkRegex(text, pattern, options, allocator)
                else
                    try cpu.processAwk(text, pattern, options, allocator);
            };
            defer searcher.deinit();
            // Use GPU regex if pattern has metacharacters
            if (use_regex) {
                break :blk searcher.processAwkRegex(text, pattern, options, allocator) catch |err| {
                    if (verbose) std.debug.print("Vulkan regex failed: {}, falling back to CPU\n", .{err});
                    break :blk try cpu.processAwkRegex(text, pattern, options, allocator);
                };
            }
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
    // safe-transpile: for with index access requires manual review
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
            std.Io.File.stdout().writeStreamingAll(init.io, str) catch {};
            std.Io.File.stdout().writeStreamingAll(init.io, "\n") catch {};
        } else if (builtin_call) |bc| {
            // Apply built-in function
            // Find the specified field
            var field_text: []const u8 = line; // Default to whole line if $0
            if (bc.field_num > 0) {
                for (result.fields) |field| {
                    // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
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
                    std.Io.File.stdout().writeStreamingAll(init.io, len_str) catch {};
                },
                .substr => {
                    // AWK substr is 1-indexed
                    // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
                    const start: usize = if (bc.arg1 > 0) @intCast(bc.arg1 - 1) else 0;
                    if (start < field_text.len) {
                        const max_len = field_text.len - start;
                        // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
                        const len: usize = if (bc.arg2 >= 0) @min(@as(usize, @intCast(bc.arg2)), max_len) else max_len;
                        std.Io.File.stdout().writeStreamingAll(init.io, field_text[start..][0..len]) catch {};
                    }
                },
                .index_fn => {
                    var buf: [32]u8 = undefined;
                    // zust: use safe.String or safe.GuardedSlice for slice operations
                    const pos: usize = if (std.mem.indexOf(u8, field_text, bc.string_arg)) |p| p + 1 else 0;
                    const pos_str = std.fmt.bufPrint(&buf, "{d}", .{pos}) catch "0";
                    std.Io.File.stdout().writeStreamingAll(init.io, pos_str) catch {};
                },
                .toupper => {
                    var upper_buf: [4096]u8 = undefined;
                    const out_len = @min(field_text.len, upper_buf.len);
                    // safe-transpile: for with index access requires manual review
                    for (field_text[0..out_len], 0..) |c, idx| {
                        upper_buf[idx] = if (c >= 'a' and c <= 'z') c - 32 else c;
                    }
                    std.Io.File.stdout().writeStreamingAll(init.io, upper_buf[0..out_len]) catch {};
                },
                .tolower => {
                    var lower_buf: [4096]u8 = undefined;
                    const out_len = @min(field_text.len, lower_buf.len);
                    // safe-transpile: for with index access requires manual review
                    for (field_text[0..out_len], 0..) |c, idx| {
                        lower_buf[idx] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                    }
                    std.Io.File.stdout().writeStreamingAll(init.io, lower_buf[0..out_len]) catch {};
                },
                .none => {
                    std.Io.File.stdout().writeStreamingAll(init.io, field_text) catch {};
                },
            }
            std.Io.File.stdout().writeStreamingAll(init.io, "\n") catch {};
        } else if (options.requested_fields.len > 0) {
            // Print specific fields
            var first = true;
            for (options.requested_fields) |field_num| {
                // Find field in result
                for (result.fields) |field| {
                    // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
                    if (field.line_idx == @as(u32, @intCast(match_idx)) and
                        field.field_idx == field_num)
                    {
                        if (!first) std.Io.File.stdout().writeStreamingAll(init.io, options.output_field_separator) catch {};
                        first = false;
                        const field_text = line[field.start_offset..field.end_offset];
                        std.Io.File.stdout().writeStreamingAll(init.io, field_text) catch {};
                        break;
                    }
                }
            }
            std.Io.File.stdout().writeStreamingAll(init.io, "\n") catch {};
        } else {
            // Print whole line
            std.Io.File.stdout().writeStreamingAll(init.io, line) catch {};
            std.Io.File.stdout().writeStreamingAll(init.io, "\n") catch {};
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

// safe-transpile: function uses raw slice parameter — consider safe.String
fn parseBackendMode(s: []const u8) BackendMode {
    if (safe.SimdUtils.eql(s, "auto")) return .auto;
    if (safe.SimdUtils.eql(s, "gpu")) return .gpu;
    if (safe.SimdUtils.eql(s, "cpu")) return .cpu;
    if (safe.SimdUtils.eql(s, "gnu")) return .cpu_gnu;
    if (safe.SimdUtils.eql(s, "metal")) return .metal;
    if (safe.SimdUtils.eql(s, "vulkan")) return .vulkan;
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
    nr, // NR - total line number across all files
    nf, // NF - number of fields
};

const ParsedProgram = struct {
    pattern: []const u8,
    action: []const u8,
    fields: []const u32,
    builtin: ?BuiltinCall = null,
    special_var: SpecialVar,
    is_gsub: bool,
    is_sub: bool,
    replacement: []const u8 = "",

    pub fn init() ParsedProgram {
        return .{
            .pattern = "",
            .action = "",
            .fields = &[_]u32{},
            .builtin = null,
            .special_var = .none,
            .is_gsub = false,
            .is_sub = false,
            .replacement = "",
        };
    }
};

// safe-transpile: function uses raw slice parameter — consider safe.String
fn parseAwkProgram(program: []const u8, allocator: std.mem.Allocator, options: *AwkOptions) !ParsedProgram {
    var result = ParsedProgram.init();
    var i: usize = 0;

    // Skip whitespace
    while (i < program.len and (program[i] == ' ' or program[i] == '\t')) i += 1;

    // Check for negated pattern: !/pattern/
    var is_negated = false;
    if (i < program.len and program[i] == '!') {
        is_negated = true;
        i += 1;
        // Skip whitespace after !
        while (i < program.len and (program[i] == ' ' or program[i] == '\t')) i += 1;
    }

    // Check for pattern: /pattern/
    if (i < program.len and program[i] == '/') {
        i += 1;
        const pattern_start = i;
        while (i < program.len and program[i] != '/') i += 1;
        result.pattern = program[pattern_start..i];
        if (i < program.len) i += 1; // Skip closing /
        if (is_negated) {
            options.invert_match = true;
        }
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

        // Check for gsub or sub
        // zust: use safe.String or safe.GuardedSlice for slice operations
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
            // zust: use safe.String or safe.GuardedSlice for slice operations
        } else if (std.mem.indexOf(u8, action, "sub(")) |sub_start| {
            result.is_sub = true;

            // Parse sub(/pattern/, "replacement")
            var j = sub_start + 4; // After "sub("

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
        // zust: use safe.String or safe.GuardedSlice for slice operations
        if (std.mem.indexOf(u8, action, "print")) |_| {
            // Check for NR (line number)
            // zust: use safe.String or safe.GuardedSlice for slice operations
            if (std.mem.indexOf(u8, action, "NR") != null) {
                result.special_var = .nr;
                // zust: use safe.String or safe.GuardedSlice for slice operations
            } else if (std.mem.indexOf(u8, action, "NF") != null) {
                result.special_var = .nf;
            }
        }

        // Check for built-in functions: length($N), substr($N, ...), index($N, ...), toupper($N), tolower($N)
        // zust: use safe.String or safe.GuardedSlice for slice operations
        if (std.mem.indexOf(u8, action, "length(")) |len_start| {
            result.builtin = parseBuiltinCall(action[len_start..], .length);
            // zust: use safe.String or safe.GuardedSlice for slice operations
        } else if (std.mem.indexOf(u8, action, "substr(")) |sub_start| {
            result.builtin = parseBuiltinCall(action[sub_start..], .substr);
            // zust: use safe.String or safe.GuardedSlice for slice operations
        } else if (std.mem.indexOf(u8, action, "index(")) |idx_start| {
            result.builtin = parseBuiltinCall(action[idx_start..], .index_fn);
            // zust: use safe.String or safe.GuardedSlice for slice operations
        } else if (std.mem.indexOf(u8, action, "toupper(")) |up_start| {
            result.builtin = parseBuiltinCall(action[up_start..], .toupper);
            // zust: use safe.String or safe.GuardedSlice for slice operations
        } else if (std.mem.indexOf(u8, action, "tolower(")) |lo_start| {
            result.builtin = parseBuiltinCall(action[lo_start..], .tolower);
        }

        // Check for print $N (if no builtin function and no special var)
        // zust: use safe.String or safe.GuardedSlice for slice operations
        if (result.builtin == null and result.special_var == .none and std.mem.indexOf(u8, action, "print") != null) {
            var fields_list: std.ArrayListUnmanaged(u32) = .empty;

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
// safe-transpile: function uses raw slice parameter — consider safe.String
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
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
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
                // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
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
        \\Pattern Matching:                                [GPU+SIMD]
        \\  /pattern/      Match lines containing pattern (regex supported)
        \\  /pattern/i     Case-insensitive pattern matching (with -i flag)
        \\
        \\Field Selection:                                 [GPU+SIMD]
        \\  $0             Entire line
        \\  $1, $2, ...    Individual fields (split by -F separator)
        \\  $NF            Last field
        \\
        \\Options:
        \\  -F SEP         Use SEP as field separator (default: whitespace)
        \\  -v var=val     Assign value to variable before execution
        \\  --assign var=val  Same as -v
        \\  -f file        Read program from file
        \\  -e 'program'   Inline program source
        \\  -i             Case-insensitive pattern matching     [GPU+SIMD]
        \\  --invert-match  Invert match (print non-matching)   [GPU+SIMD]
        \\  -c, --traditional  Traditional mode (no GNU extensions)
        \\  -P, --posix     POSIX compatibility mode
        \\  --lint         Enable lint warnings
        \\  --dump-variables Dump variables to file on exit
        \\  --profile      Enable profiling
        \\  --backend MODE Backend: auto, cpu, gnu, gpu, metal, vulkan
        \\  --cpu          Force CPU backend (SIMD-optimized)
        \\  --gnu          Force GNU backend (gawk reference)
        \\  --gpu          Force GPU (Metal on macOS, Vulkan otherwise)
        \\  --metal        Force Metal backend (macOS)
        \\  --vulkan       Force Vulkan backend (macOS+gnu or Linux)
        \\  --verbose      Print backend selection and timing info
        \\  --version      Print version information
        \\  -h, --help     Show this help
        \\
        \\Built-in Functions:                              [GPU+SIMD]
        \\  length($N)         Return length of field N
        \\  substr($N, s, l)   Substring of field N from position s, length l
        \\  index($N, "str")   Position of "str" in field N (0 if not found)
        \\  toupper($N)        Convert field N to uppercase
        \\  tolower($N)        Convert field N to lowercase
        \\
        \\Substitution:                                    [GPU+SIMD]
        \\  gsub(/pat/, "rep") Replace all occurrences of pattern with replacement
        \\  sub(/pat/, "rep")  Replace first occurrence of pattern with replacement
        \\
        \\Advanced Features (GPU Bytecode VM):            [GPU]
        \\  BEGIN { }      Execute before processing any input
        \\  END { }        Execute after processing all input
        \\  if/else/while/for  Control flow statements
        \\  Variables      User-defined variables and arithmetic
        \\  Math functions sin(), cos(), sqrt(), log(), exp(), int()
        \\
        \\Advanced Features (CPU only):
        \\  printf         Formatted output
        \\  Arrays         Associative arrays a[key]
        \\  User functions User-defined functions
        \\
        \\Optimization Notes:
        \\  [GPU+SIMD] Pattern matching uses Thompson NFA on GPU compute shaders.
        \\             Field extraction and string functions run in parallel on GPU.
        \\             CPU fallback uses 16/32-byte SIMD vector operations.
        \\  [GPU VM]   Complex AWK programs compile to bytecode and execute on GPU.
        \\             Each input line is processed by a separate GPU thread.
        \\  [CPU]      Programs with arrays, printf, or user functions use CPU evaluator.
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

/// Check if an AWK program needs the full parser/evaluator
/// Returns true for complex programs with:
/// - BEGIN/END blocks
/// - Multiple rules
/// - Variables and arithmetic
/// - Control flow (if/while/for)
/// - User-defined functions
// safe-transpile: function uses raw slice parameter — consider safe.String
fn needsFullParser(program: []const u8) bool {
    // Keywords that indicate complex programs
    const complex_keywords = [_][]const u8{
        "BEGIN",
        "END",
        "if",
        "else",
        "while",
        "for",
        "function",
        "return",
        "break",
        "continue",
        "next",
        "exit",
        "delete",
        "printf",
        "gensub",
        "match",
        "asort",
        "asorti",
        "typeof",
        "and",
        "or",
        "xor",
        "compl",
        "lshift",
        "rshift",
        "IGNORECASE",
    };

    for (complex_keywords) |kw| {
        // zust: use safe.String or safe.GuardedSlice for slice operations
        if (std.mem.indexOf(u8, program, kw) != null) {
            return true;
        }
    }

    // Check for variable assignments (x = ..., not == comparison)
    var i: usize = 0;
    while (i < program.len) {
        // Skip strings
        if (program[i] == '"') {
            i += 1;
            while (i < program.len and program[i] != '"') {
                if (program[i] == '\\' and i + 1 < program.len) i += 1;
                i += 1;
            }
            if (i < program.len) i += 1;
            continue;
        }

        // Skip regexes
        if (program[i] == '/') {
            i += 1;
            while (i < program.len and program[i] != '/') {
                if (program[i] == '\\' and i + 1 < program.len) i += 1;
                i += 1;
            }
            if (i < program.len) i += 1;
            continue;
        }

        // Check for assignment (identifier followed by = but not ==)
        if (std.ascii.isAlphabetic(program[i]) or program[i] == '_') {
            const ident_start = i;
            while (i < program.len and (std.ascii.isAlphanumeric(program[i]) or program[i] == '_')) {
                i += 1;
            }

            // Skip whitespace
            while (i < program.len and (program[i] == ' ' or program[i] == '\t')) i += 1;

            // Check for assignment operators
            if (i < program.len and program[i] == '=' and (i + 1 >= program.len or program[i + 1] != '=')) {
                // It's an assignment - check if it's not inside gsub()
                const before = program[0..ident_start];
                // Exclude assignments inside gsub()/sub() which use = as regex delimiter
                // zust: use safe.String or safe.GuardedSlice for slice operations
                if (std.mem.indexOf(u8, before, "gsub(") == null and
                    // zust: use safe.String or safe.GuardedSlice for slice operations
                    std.mem.indexOf(u8, before, "sub(") == null)
                {
                    return true;
                }
            }

            // Check for compound assignment
            if (i + 1 < program.len and
                (safe.SimdUtils.eql(program[i .. i + 2], "+=") or
                    safe.SimdUtils.eql(program[i .. i + 2], "-=") or
                    safe.SimdUtils.eql(program[i .. i + 2], "*=") or
                    safe.SimdUtils.eql(program[i .. i + 2], "/=") or
                    safe.SimdUtils.eql(program[i .. i + 2], "%=") or
                    safe.SimdUtils.eql(program[i .. i + 2], "^=")))
            {
                return true;
            }
        }

        i += 1;
    }

    // Check for multiple action blocks (more than one { })
    var brace_count: u32 = 0;
    for (program) |c| {
        if (c == '{') brace_count += 1;
    }
    if (brace_count > 1) return true;

    return false;
}

/// Execute a complex AWK program using the full parser/evaluator
// safe-transpile: function uses raw slice parameter — consider safe.String
// safe-transpile: function returns small constant slice — consider safe.String
fn readFileToEndAlloc(file: std.Io.File, io: std.Io, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
    const stat = try file.stat(io);
    const size = @min(stat.size, max_size);
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    var total_read: usize = 0;
    while (total_read < size) {
        const n = try file.readStreaming(io, &.{buf[total_read..]});
        if (n == 0) break;
        total_read += n;
    }
    if (total_read < size) {
        const trimmed = try allocator.realloc(buf, total_read);
        return trimmed;
    }
    return buf;
}

fn readFileToString(allocator: std.mem.Allocator, path: []const u8, io: std.Io) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    var total_read: usize = 0;
    while (total_read < stat.size) {
        const n = try file.readStreaming(io, &.{buf[total_read..]});
        if (n == 0) break;
        total_read += n;
    }
    if (total_read < stat.size) {
        return buf[0..total_read];
    }
    return buf;
}

// safe-transpile: function uses raw slice parameter — consider safe.String
// safe-transpile: function returns small constant slice — consider safe.String
fn executeFullAwk(program_text: []const u8, input: []const u8, field_separator: []const u8, variables: std.StringHashMapUnmanaged([]const u8), allocator: std.mem.Allocator, filename: ?[]const u8) ![]const u8 {
    var p = parser.Parser.init(program_text, allocator);
    var program = p.parse() catch {
        return error.ParseError;
    };
    defer program.deinit();

    var eval = evaluator.Evaluator.init(allocator, &program.functions);
    defer eval.deinit();

    // Set field separator if provided
    if (!safe.SimdUtils.eql(field_separator, " \t")) {
        eval.field_separator = field_separator;
    }

    // Set variables from -v assignments
    var var_it = variables.iterator();
    while (var_it.next()) |entry| {
        const val = Value.initString(entry.value_ptr.*);
        try eval.variables.put(allocator, entry.key_ptr.*, val);
    }

    return eval.execute(&program, input, filename, true);
}

/// Execute full AWK program on GPU using bytecode VM
// safe-transpile: function uses raw slice parameter — consider safe.String
// safe-transpile: function returns small constant slice — consider safe.String
fn executeFullAwkGpu(
    program_text: []const u8,
    input: []const u8,
    options: AwkOptions,
    backend_mode: BackendMode,
    verbose: bool,
    allocator: std.mem.Allocator,
) ![]u8 {
    // Parse the AWK program
    var p = parser.Parser.init(program_text, allocator);
    var program = p.parse() catch {
        return error.ParseError;
    };
    defer program.deinit();

    // Compile to bytecode
    var compiler = bytecode.Compiler.init(allocator);
    defer compiler.deinit();
    var compiled = compiler.compile(&program) catch {
        return error.CompileError;
    };
    defer compiled.deinit();

    if (verbose) {
        std.debug.print("Compiled AWK program to {} bytecode instructions\n", .{compiled.instructions.len});
    }

    // Convert to GPU-compatible format (same layout, just need to reinterpret)
    const gpu_instructions = try allocator.alloc(gpu.Instruction, compiled.instructions.len);
    // safe-transpile: free removed (memory owned by safe type);
    // safe-transpile: for with index access requires manual review
    for (compiled.instructions, 0..) |inst, i| {
        // bytecode.Instruction has same layout as gpu.Instruction
        gpu_instructions[i] = .{
            .opcode = inst.opcode,
            .arg1 = inst.arg1,
            .arg2 = inst.arg2,
            .arg3 = inst.arg3,
        };
    }

    const gpu_constants = try allocator.alloc(f32, compiled.num_constants.len);
    // safe-transpile: free removed (memory owned by safe type);
    // safe-transpile: for with index access requires manual review
    for (compiled.num_constants, 0..) |c, i| {
        gpu_constants[i] = @floatCast(c);
    }

    const gpu_bc = gpu.GpuBytecode{
        .instructions = gpu_instructions,
        .num_constants = gpu_constants,
        .main_offset = compiled.main_offset,
        .num_variables = compiled.num_variables,
        .allocator = allocator,
    };

    // Select backend and execute
    const backend = selectBackend(backend_mode, input.len, verbose);

    switch (backend) {
        .metal => {
            if (build_options.is_macos) {
                const searcher = gpu.metal.MetalAwk.init(allocator) catch {
                    return error.GpuInitFailed;
                };
                defer searcher.deinit();

                if (!searcher.hasVmSupport()) {
                    return error.VmNotSupported;
                }

                if (verbose) std.debug.print("Executing AWK program on Metal GPU bytecode VM\n", .{});
                return searcher.executeBytecode(gpu_bc, input, options, allocator);
            } else {
                return error.MetalNotAvailable;
            }
        },
        .vulkan => {
            // TODO: Implement Vulkan bytecode VM execution
            return error.VmNotSupported;
        },
        .cpu, .cuda, .opencl => {
            return error.CpuBackendSelected;
        },
    }
}
