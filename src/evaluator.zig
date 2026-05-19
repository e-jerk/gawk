const std = @import("std");
const safe = @import("safe");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const parser = @import("parser.zig");
const regex = @import("regex");

// ============================================================================
// AWK Program Evaluator
// Executes a parsed AST against input data
// ============================================================================

pub const EvalError = error{
    DivisionByZero,
    InvalidField,
    InvalidArray,
    UndefinedFunction,
    BreakOutsideLoop,
    ContinueOutsideLoop,
    NextOutsideRule,
    MaxIterationsExceeded,
    OutOfMemory,
    InvalidRegex,
    IoError,
};

/// Control flow signals
const ControlFlow = enum {
    normal,
    break_loop,
    continue_loop,
    next_line,
    next_file,
    exit_program,
    return_value,
};

/// Evaluator state for executing AWK programs
pub const Evaluator = struct {
    allocator: Allocator,

    /// Global variables
    variables: std.StringHashMapUnmanaged(Value),

    /// Arrays (name -> key -> value)
    arrays: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(Value)),

    /// User-defined functions from the program
    functions: *std.StringHashMapUnmanaged(ast.Function),

    /// Current input line ($0)
    current_line: []const u8 = "",

    /// Current fields (computed lazily from current_line)
    fields: std.ArrayListUnmanaged([]const u8) = .{},

    /// Open files for getline redirection
    open_files: std.StringHashMapUnmanaged(std.fs.File) = .{},

    /// Open output files for print/printf redirection
    open_output_files: std.StringHashMapUnmanaged(std.fs.File) = .{},

    /// Field separator
    field_separator: []const u8 = " \t",

    /// Output field separator
    ofs: []const u8 = " ",

    /// Output record separator
    ors: []const u8 = "\n",

    /// Record separator
    rs: []const u8 = "\n",

    /// IGNORECASE flag
    ignorecase: bool = false,

    /// Line number (NR)
    nr: u64 = 0,

    /// File line number (FNR)
    fnr: u64 = 0,

    /// Number of fields in current line (NF)
    nf: u64 = 0,

    /// Current filename
    filename: []const u8 = "",

    /// RSTART: start position of last match (1-based, 0 if no match)
    rstart: u64 = 0,

    /// RLENGTH: length of last match (-1 if no match)
    rlength: i64 = -1,

    /// Output buffer
    output: std.ArrayListUnmanaged(u8) = .{},

    /// Control flow state
    control: ControlFlow = .normal,

    /// Return value from function
    return_value: Value = Value.initEmpty(),

    /// Exit code
    exit_code: i32 = 0,

    /// Loop depth (for break/continue validation)
    loop_depth: u32 = 0,

    /// Maximum iterations per loop (protection against infinite loops)
    max_iterations: u32 = 10_000_000,

    pub fn init(allocator: Allocator, functions: *std.StringHashMapUnmanaged(ast.Function)) Evaluator {
        var ev = Evaluator{
            .allocator = allocator,
            .variables = .{},
            .arrays = .{},
            .functions = functions,
            .output = .{},
        };
        // Initialize ENVIRON array with environment variables
        var env_map = std.process.getEnvMap(allocator) catch return ev;
        defer env_map.deinit();
        var env_array = std.StringHashMapUnmanaged(Value){};
        var it = env_map.iterator();
        while (it.next()) |entry| {
            const key = allocator.dupe(u8, entry.key_ptr.*) catch continue;
            const val_str = allocator.dupe(u8, entry.value_ptr.*) catch continue;
            const val = Value.initStringOwned(val_str, allocator);
            env_array.put(allocator, key, val) catch continue;
        }
        ev.arrays.put(allocator, "ENVIRON", env_array) catch {};
        return ev;
    }

    pub fn deinit(self: *Evaluator) void {
        var var_it = self.variables.iterator();
        while (var_it.next()) |entry| {
            var v = entry.value_ptr.*;
            v.deinit();
        }
        self.variables.deinit(self.allocator);

        var arr_it = self.arrays.iterator();
        while (arr_it.next()) |entry| {
            var inner_it = entry.value_ptr.iterator();
            while (inner_it.next()) |inner_entry| {
                var v = inner_entry.value_ptr.*;
                v.deinit();
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.arrays.deinit(self.allocator);

        self.fields.deinit(self.allocator);
        self.output.deinit(self.allocator);

        var file_it = self.open_files.iterator();
        while (file_it.next()) |entry| {
            entry.value_ptr.close();
        }
        self.open_files.deinit(self.allocator);

        var out_file_it = self.open_output_files.iterator();
        while (out_file_it.next()) |entry| {
            entry.value_ptr.close();
        }
        self.open_output_files.deinit(self.allocator);

        if (self.return_value.flags.string_owned) {
            self.return_value.deinit();
        }
    }

    /// Execute a complete AWK program on input text
    /// If filename is provided, sets FILENAME and resets FNR (for multi-file processing)
    /// run_end controls whether END block executes (set to false for intermediate files in multi-file mode)
    // safe-transpile: function uses raw slice parameter — consider safe.String
    // safe-transpile: function returns small constant slice — consider safe.String
    pub fn execute(self: *Evaluator, program: *ast.Program, input: []const u8, maybe_filename: ?[]const u8, run_end: bool) ![]const u8 {
        // Reset control state at start of each file
        self.control = .normal;

        // Set filename if provided
        if (maybe_filename) |fname| {
            self.filename = fname;
            self.fnr = 0;
        }

        // Execute BEGIN block (only on first call)
        if (self.nr == 0) {
            if (program.begin) |begin| {
                try self.executeStatement(begin);
                if (self.control == .exit_program) {
                    return try self.output.toOwnedSlice(self.allocator);
                }
                self.control = .normal;
            }
        }

        // Execute BEGINFILE block (before each file)
        if (maybe_filename != null) {
            if (program.beginfile) |beginfile| {
                try self.executeStatement(beginfile);
                if (self.control == .exit_program) {
                    return try self.output.toOwnedSlice(self.allocator);
                }
                self.control = .normal;
            }
        }

        // Process each input record based on RS
        var records: std.ArrayListUnmanaged([]const u8) = .{};
        defer records.deinit(self.allocator);
        if (self.rs.len == 0) {
            // Paragraph mode: split on one or more blank lines
            var start: usize = 0;
            var i: usize = 0;
            while (i < input.len) {
                if (input[i] == '\n') {
                    var blank_count: usize = 1;
                    var j = i + 1;
                    while (j < input.len and input[j] == '\n') : (j += 1) {
                        blank_count += 1;
                    }
                    if (blank_count >= 2) {
                        // End of paragraph; record is text before the blank lines
                        const rec = input[start..i];
                        if (rec.len > 0) {
                            try records.append(self.allocator, rec);
                        }
                        start = j;
                        i = j;
                    } else {
                        i += 1;
                    }
                } else {
                    i += 1;
                }
            }
            if (start < input.len) {
                const rec = input[start..];
                if (rec.len > 0) {
                    try records.append(self.allocator, rec);
                }
            }
        } else if (self.rs.len == 1) {
            // Single-character RS
            var iter = std.mem.splitScalar(u8, input, self.rs[0]);
            while (iter.next()) |rec| {
                try records.append(self.allocator, rec);
            }
        } else {
            // Multi-character RS
            var iter = std.mem.splitSequence(u8, input, self.rs);
            while (iter.next()) |rec| {
                try records.append(self.allocator, rec);
            }
        }

        for (records.items) |line| {
            // Skip trailing empty record from final RS
            if (line.len == 0) {
                // Only skip if it's the very last record and input ended with RS
                const is_last = (&line[0] == &records.items[records.items.len - 1][0]);
                if (is_last and (input.len == 0 or input[input.len - 1] == self.rs[0])) continue;
            }
            self.nr += 1;
            self.fnr += 1;
            self.setCurrentLine(line);

            // Execute rules
            for (program.rules) |rule| {
                // Check pattern
                var matches = true;
                if (rule.pattern) |pattern| {
                    const pattern_result = try self.evaluateExpression(pattern);
                    matches = pattern_result.isTruthy();
                }

                if (matches) {
                    try self.executeStatement(rule.action);
                }

                if (self.control == .exit_program or self.control == .next_file) break;
            }

            if (self.control == .exit_program or self.control == .next_file) break;
        }

        // Execute ENDFILE block (after each file)
        if (maybe_filename != null) {
            if (program.endfile) |endfile| {
                self.control = .normal;
                try self.executeStatement(endfile);
            }
        }

        // Execute END block (only on last file or single file)
        if (run_end) {
            if (program.end) |end| {
                self.control = .normal;
                try self.executeStatement(end);
            }
        }

        return try self.output.toOwnedSlice(self.allocator);
    }

    // safe-transpile: function uses raw slice parameter — consider safe.String
    fn setCurrentLine(self: *Evaluator, line: []const u8) void {
        self.current_line = line;
        self.fields.clearRetainingCapacity();

        // Split line into fields
        if (safe.SimdUtils.eql(self.field_separator, " \t")) {
            // Default: split on whitespace, collapse multiple spaces
            var in_field = false;
            var field_start: usize = 0;

            // safe-transpile: for with index access requires manual review
            for (line, 0..) |c, i| {
                const is_space = c == ' ' or c == '\t';
                if (is_space) {
                    if (in_field) {
                        self.fields.append(self.allocator, line[field_start..i]) catch {};
                        in_field = false;
                    }
                } else {
                    if (!in_field) {
                        field_start = i;
                        in_field = true;
                    }
                }
            }
            if (in_field) {
                self.fields.append(self.allocator, line[field_start..]) catch {};
            }
        } else if (self.field_separator.len == 1) {
            // Single-character separator
            var iter = std.mem.splitScalar(u8, line, self.field_separator[0]);
            while (iter.next()) |field| {
                self.fields.append(self.allocator, field) catch {};
            }
        } else {
            // Multi-character separator
            var iter = std.mem.splitSequence(u8, line, self.field_separator);
            while (iter.next()) |field| {
                self.fields.append(self.allocator, field) catch {};
            }
        }

        self.nf = self.fields.items.len;
    }

    fn executeStatement(self: *Evaluator, stmt: *ast.Statement) !void {
        if (self.control != .normal) return;

        switch (stmt.kind) {
            .block => |stmts| {
                for (0..stmts.len) |__zust_i| {
                    const s = &stmts[__zust_i];
                    var inner_stmt = s.*;
                    try self.executeStatement(&inner_stmt);
                    if (self.control != .normal) return;
                }
            },

            .expression => |expr| {
                _ = try self.evaluateExpression(expr);
            },

            .print => |p| {
                try self.executePrint(p.args, p.output_file, p.append, p.pipe_cmd);
            },

            .printf => |pf| {
                try self.executePrintf(pf.format, pf.args, pf.output_file, pf.append, pf.pipe_cmd);
            },

            .if_stmt => |is| {
                const cond = try self.evaluateExpression(is.condition);
                if (cond.isTruthy()) {
                    try self.executeStatement(is.then_branch);
                } else if (is.else_branch) |eb| {
                    try self.executeStatement(eb);
                }
            },

            .while_stmt => |ws| {
                self.loop_depth += 1;
                defer self.loop_depth -= 1;

                var iterations: u32 = 0;
                while (iterations < self.max_iterations) : (iterations += 1) {
                    const cond = try self.evaluateExpression(ws.condition);
                    if (!cond.isTruthy()) break;

                    try self.executeStatement(ws.body);

                    if (self.control == .break_loop) {
                        self.control = .normal;
                        break;
                    }
                    if (self.control == .continue_loop) {
                        self.control = .normal;
                        continue;
                    }
                    if (self.control != .normal) return;
                }
            },

            .do_while_stmt => |dw| {
                self.loop_depth += 1;
                defer self.loop_depth -= 1;

                var iterations: u32 = 0;
                while (iterations < self.max_iterations) : (iterations += 1) {
                    try self.executeStatement(dw.body);

                    if (self.control == .break_loop) {
                        self.control = .normal;
                        break;
                    }
                    if (self.control == .continue_loop) {
                        self.control = .normal;
                    }
                    if (self.control != .normal) return;

                    const cond = try self.evaluateExpression(dw.condition);
                    if (!cond.isTruthy()) break;
                }
            },

            .for_stmt => |fs| {
                self.loop_depth += 1;
                defer self.loop_depth -= 1;

                // Init
                if (fs.init) |init_stmt| {
                    try self.executeStatement(init_stmt);
                }

                var iterations: u32 = 0;
                while (iterations < self.max_iterations) : (iterations += 1) {
                    // Condition
                    if (fs.condition) |cond| {
                        const result = try self.evaluateExpression(cond);
                        if (!result.isTruthy()) break;
                    }

                    // Body
                    try self.executeStatement(fs.body);

                    if (self.control == .break_loop) {
                        self.control = .normal;
                        break;
                    }
                    if (self.control == .continue_loop) {
                        self.control = .normal;
                    }
                    if (self.control != .normal) return;

                    // Update
                    if (fs.update) |update| {
                        _ = try self.evaluateExpression(update);
                    }
                }
            },

            .for_in_stmt => |fis| {
                self.loop_depth += 1;
                defer self.loop_depth -= 1;

                if (self.arrays.get(fis.array_name)) |*array| {
                    var it = array.iterator();
                    while (it.next()) |entry| {
                        try self.setVariable(fis.var_name, Value.initString(entry.key_ptr.*));

                        try self.executeStatement(fis.body);

                        if (self.control == .break_loop) {
                            self.control = .normal;
                            break;
                        }
                        if (self.control == .continue_loop) {
                            self.control = .normal;
                            continue;
                        }
                        if (self.control != .normal) return;
                    }
                }
            },

            .break_stmt => {
                if (self.loop_depth == 0) return EvalError.BreakOutsideLoop;
                self.control = .break_loop;
            },

            .continue_stmt => {
                if (self.loop_depth == 0) return EvalError.ContinueOutsideLoop;
                self.control = .continue_loop;
            },

            .next_stmt => {
                self.control = .next_line;
            },

            .nextfile_stmt => {
                self.control = .next_file;
            },

            .exit_stmt => |exit_expr| {
                if (exit_expr) |expr| {
                    const val = try self.evaluateExpression(expr);
                    self.exit_code = @intFromFloat(val.asNumber());
                }
                self.control = .exit_program;
            },

            .return_stmt => |ret_expr| {
                if (ret_expr) |expr| {
                    self.return_value = try self.evaluateExpression(expr);
                } else {
                    self.return_value = Value.initEmpty();
                }
                self.control = .return_value;
            },

            .delete_stmt => |ds| {
                if (self.arrays.getPtr(ds.array)) |array| {
                    if (ds.index) |index_expr| {
                        const key = try self.evaluateExpression(index_expr);
                        const key_str = try key.asString(self.allocator);
                        _ = array.remove(key_str);
                    } else {
                        // Delete entire array
                        var it = array.iterator();
                        while (it.next()) |entry| {
                            var v = entry.value_ptr.*;
                            v.deinit();
                        }
                        array.clearAndFree(self.allocator);
                    }
                }
            },

            .getline_stmt => |gl| {
                const result = try self.executeGetline(gl.var_name, gl.file, null);
                // getline statement result is ignored in statement context
                _ = result;
            },

            .empty => {},
        }
    }

    fn executeGetline(self: *Evaluator, var_name: ?[]const u8, file_expr: ?*ast.Expression, pipe_expr: ?*ast.Expression) !Value {
        _ = pipe_expr; // TODO: Support pipe getline

        var line_buf: [4096]u8 = .{};
        var line: ?[]const u8 = null;

        if (file_expr) |fe| {
            const file_val = try self.evaluateExpression(fe);
            const file_str = try file_val.asString(self.allocator);

            // Check if file is already open
            if (self.open_files.get(file_str)) |*file| {
                const bytes_read = file.read(&line_buf) catch return Value.initNumber(-1.0);
                if (bytes_read == 0) return Value.initNumber(0.0);
                // Find newline
                if (std.mem.indexOfScalar(u8, line_buf[0..bytes_read], '\n')) |nl| {
                    line = line_buf[0..nl];
                    // Seek back if we read past newline
                    const past_newline = bytes_read - nl - 1;
                    if (past_newline > 0) {
                        // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
                        file.seekBy(-@as(i64, @intCast(past_newline))) catch {};
                    }
                } else {
                    line = line_buf[0..bytes_read];
                }
            } else {
                const new_file = std.fs.cwd().openFile(file_str, .{}) catch return Value.initNumber(-1.0);
                try self.open_files.put(self.allocator, try self.allocator.dupe(u8, file_str), new_file);
                const bytes_read = new_file.read(&line_buf) catch return Value.initNumber(-1.0);
                if (bytes_read == 0) return Value.initNumber(0.0);
                if (std.mem.indexOfScalar(u8, line_buf[0..bytes_read], '\n')) |nl| {
                    line = line_buf[0..nl];
                    const past_newline = bytes_read - nl - 1;
                    if (past_newline > 0) {
                        // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
                        new_file.seekBy(-@as(i64, @intCast(past_newline))) catch {};
                    }
                } else {
                    line = line_buf[0..bytes_read];
                }
            }
        } else {
            // Read from next line of current input
            // For now, return EOF
            return Value.initNumber(0.0);
        }

        if (line) |l| {
            if (var_name) |vn| {
                try self.setVariable(vn, Value.initString(l));
            } else {
                // Default: assign to $0
                self.setCurrentLine(l);
            }
            return Value.initNumber(1.0);
        }

        return Value.initNumber(0.0);
    }

    // safe-transpile: function uses raw slice parameter — consider safe.String
    fn writeToOutput(self: *Evaluator, output_file: ?*ast.Expression, append: bool, pipe_cmd: ?*ast.Expression, data: []const u8) !void {
        if (pipe_cmd) |pc| {
            const cmd_val = try self.evaluateExpression(pc);
            const cmd_str = try cmd_val.asString(self.allocator);

            // Simple pipe: spawn command, write data to stdin, wait
            var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd_str }, self.allocator);
            child.stdin_behavior = .Pipe;
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;

            child.spawn() catch return error.IoError;
            if (child.stdin) |*stdin| {
                _ = stdin.write(data) catch {};
                stdin.close();
                child.stdin = null;
            }
            _ = child.wait() catch {};
            return;
        }

        if (output_file) |of| {
            const file_val = try self.evaluateExpression(of);
            const file_str = try file_val.asString(self.allocator);

            // Check if file is already open
            if (self.open_output_files.get(file_str)) |*file| {
                _ = file.write(data) catch {};
            } else {
                const new_file = blk: {
                    if (append) {
                        var file = std.fs.cwd().openFile(file_str, .{ .mode = .read_write }) catch {
                            const created = std.fs.cwd().createFile(file_str, .{ .truncate = false }) catch return;
                            break :blk created;
                        };
                        file.seekFromEnd(0) catch {};
                        break :blk file;
                    } else {
                        break :blk std.fs.cwd().createFile(file_str, .{}) catch return;
                    }
                };

                const key = try self.allocator.dupe(u8, file_str);
                try self.open_output_files.put(self.allocator, key, new_file);
                _ = new_file.write(data) catch {};
            }
        } else {
            try self.output.appendSlice(self.allocator, data);
        }
    }

    fn executePrint(self: *Evaluator, args: []*ast.Expression, output_file: ?*ast.Expression, append: bool, pipe_cmd: ?*ast.Expression) !void {
        var line_output: std.ArrayListUnmanaged(u8) = .{};
        defer line_output.deinit(self.allocator);

        if (args.len == 0) {
            // print $0
            try line_output.appendSlice(self.allocator, self.current_line);
        } else {
            // safe-transpile: for with index access requires manual review
            for (args, 0..) |arg, i| {
                if (i > 0) try line_output.appendSlice(self.allocator, self.ofs);
                const val = try self.evaluateExpression(arg);
                const str = try val.asString(self.allocator);
                try line_output.appendSlice(self.allocator, str);
            }
        }
        try line_output.appendSlice(self.allocator, self.ors);

        try self.writeToOutput(output_file, append, pipe_cmd, line_output.items);
    }

    fn executePrintf(self: *Evaluator, format_expr: *ast.Expression, args: []*ast.Expression, output_file: ?*ast.Expression, append: bool, pipe_cmd: ?*ast.Expression) !void {
        const format_val = try self.evaluateExpression(format_expr);
        const format_str = try format_val.asString(self.allocator);

        var printf_output: std.ArrayListUnmanaged(u8) = .{};
        defer printf_output.deinit(self.allocator);

        // Simple printf implementation
        var arg_idx: usize = 0;
        var i: usize = 0;
        while (i < format_str.len) {
            if (format_str[i] == '%' and i + 1 < format_str.len) {
                i += 1;
                if (format_str[i] == '%') {
                    try printf_output.append(self.allocator, '%');
                    i += 1;
                    continue;
                }

                // Skip flags, width, precision
                while (i < format_str.len and (format_str[i] == '-' or format_str[i] == '+' or
                    format_str[i] == ' ' or format_str[i] == '#' or format_str[i] == '0'))
                {
                    i += 1;
                }
                while (i < format_str.len and format_str[i] >= '0' and format_str[i] <= '9') {
                    i += 1;
                }
                if (i < format_str.len and format_str[i] == '.') {
                    i += 1;
                    while (i < format_str.len and format_str[i] >= '0' and format_str[i] <= '9') {
                        i += 1;
                    }
                }

                if (i >= format_str.len) break;

                const spec = format_str[i];
                i += 1;

                if (arg_idx < args.len) {
                    const val = try self.evaluateExpression(args[arg_idx]);
                    arg_idx += 1;

                    switch (spec) {
                        'd', 'i' => {
                            const n: i64 = @intFromFloat(val.asNumber());
                            const formatted = try std.fmt.allocPrint(self.allocator, "{d}", .{n});
                            // safe-transpile: free removed (memory owned by safe type);
                            try printf_output.appendSlice(self.allocator, formatted);
                        },
                        'f', 'e', 'g' => {
                            const formatted = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{val.asNumber()});
                            // safe-transpile: free removed (memory owned by safe type);
                            try printf_output.appendSlice(self.allocator, formatted);
                        },
                        's' => {
                            const str = try val.asString(self.allocator);
                            try printf_output.appendSlice(self.allocator, str);
                        },
                        'c' => {
                            const n: u8 = @intFromFloat(val.asNumber());
                            try printf_output.append(self.allocator, n);
                        },
                        else => {},
                    }
                }
            } else {
                // Handle escape sequences
                if (format_str[i] == '\\' and i + 1 < format_str.len) {
                    i += 1;
                    switch (format_str[i]) {
                        'n' => try printf_output.append(self.allocator, '\n'),
                        't' => try printf_output.append(self.allocator, '\t'),
                        'r' => try printf_output.append(self.allocator, '\r'),
                        '\\' => try printf_output.append(self.allocator, '\\'),
                        else => {
                            try printf_output.append(self.allocator, '\\');
                            try printf_output.append(self.allocator, format_str[i]);
                        },
                    }
                    i += 1;
                } else {
                    try printf_output.append(self.allocator, format_str[i]);
                    i += 1;
                }
            }
        }

        try self.writeToOutput(output_file, append, pipe_cmd, printf_output.items);
    }

    fn evaluateExpression(self: *Evaluator, expr: *ast.Expression) EvalError!Value {
        switch (expr.kind) {
            .number_literal => |n| return Value.initNumber(n),

            .string_literal => |s| return Value.initString(s),

            .regex_literal => |pattern| {
                // When used as expression, match against $0
                if (self.matchRegex(self.current_line, pattern)) {
                    return Value.initNumber(1.0);
                }
                return Value.initNumber(0.0);
            },

            .whole_line => return Value.initString(self.current_line),

            .field_ref => |index_expr| {
                const index_val = try self.evaluateExpression(index_expr);
                const index: usize = @intFromFloat(index_val.asNumber());

                if (index == 0) {
                    return Value.initString(self.current_line);
                }
                if (index <= self.fields.items.len) {
                    return Value.initString(self.fields.items[index - 1]);
                }
                return Value.initEmpty();
            },

            .variable => |name| {
                // Check special variables first
                if (safe.SimdUtils.eql(name, "NR")) return Value.initNumber(@floatFromInt(self.nr));
                if (safe.SimdUtils.eql(name, "NF")) return Value.initNumber(@floatFromInt(self.nf));
                if (safe.SimdUtils.eql(name, "FNR")) return Value.initNumber(@floatFromInt(self.fnr));
                if (safe.SimdUtils.eql(name, "FS")) return Value.initString(self.field_separator);
                if (safe.SimdUtils.eql(name, "OFS")) return Value.initString(self.ofs);
                if (safe.SimdUtils.eql(name, "ORS")) return Value.initString(self.ors);
                if (safe.SimdUtils.eql(name, "RS")) return Value.initString(self.rs);
                if (safe.SimdUtils.eql(name, "IGNORECASE")) return Value.initNumber(if (self.ignorecase) 1.0 else 0.0);
                if (safe.SimdUtils.eql(name, "FILENAME")) return Value.initString(self.filename);
                if (safe.SimdUtils.eql(name, "RSTART")) return Value.initNumber(@floatFromInt(self.rstart));
                if (safe.SimdUtils.eql(name, "RLENGTH")) return Value.initNumber(@floatFromInt(self.rlength));

                if (self.variables.get(name)) |val| {
                    return val;
                }
                return Value.initEmpty();
            },

            .array_subscript => |as| {
                const key = try self.evaluateExpression(as.index);
                const key_str = key.asString(self.allocator) catch "";

                if (self.arrays.get(as.array)) |array| {
                    if (array.get(key_str)) |val| {
                        return val;
                    }
                }
                return Value.initEmpty();
            },

            .binary_op => |bo| {
                const left = try self.evaluateExpression(bo.left);
                const right = try self.evaluateExpression(bo.right);

                return switch (bo.op) {
                    .add => Value.add(&left, &right),
                    .sub => Value.sub(&left, &right),
                    .mul => Value.mul(&left, &right),
                    .div => Value.div(&left, &right),
                    .mod => Value.mod(&left, &right),
                    .pow => Value.pow(&left, &right),
                    .lt => Value.initNumber(if (Value.compare(&left, &right, .lt)) 1.0 else 0.0),
                    .le => Value.initNumber(if (Value.compare(&left, &right, .le)) 1.0 else 0.0),
                    .gt => Value.initNumber(if (Value.compare(&left, &right, .gt)) 1.0 else 0.0),
                    .ge => Value.initNumber(if (Value.compare(&left, &right, .ge)) 1.0 else 0.0),
                    .eq => Value.initNumber(if (Value.compare(&left, &right, .eq)) 1.0 else 0.0),
                    .ne => Value.initNumber(if (Value.compare(&left, &right, .ne)) 1.0 else 0.0),
                    .@"and" => Value.initNumber(if (left.isTruthy() and right.isTruthy()) 1.0 else 0.0),
                    .@"or" => Value.initNumber(if (left.isTruthy() or right.isTruthy()) 1.0 else 0.0),
                    .concat => left.concat(&right, self.allocator) catch Value.initEmpty(),
                    .match, .not_match => Value.initNumber(0.0), // Handled by regex_match
                };
            },

            .unary_op => |uo| {
                const operand = try self.evaluateExpression(uo.operand);
                return switch (uo.op) {
                    .negate => operand.negate(),
                    .not => Value.initNumber(if (!operand.isTruthy()) 1.0 else 0.0),
                    .pre_incr, .post_incr => blk: {
                        const new_val = operand.increment();
                        try self.assignToExpr(uo.operand, new_val);
                        break :blk if (uo.prefix) new_val else operand;
                    },
                    .pre_decr, .post_decr => blk: {
                        const new_val = operand.decrement();
                        try self.assignToExpr(uo.operand, new_val);
                        break :blk if (uo.prefix) new_val else operand;
                    },
                };
            },

            .assignment => |a| {
                var value = try self.evaluateExpression(a.value);

                if (a.op) |op| {
                    const current = try self.evaluateExpression(a.target);
                    value = switch (op) {
                        .add_assign => Value.add(&current, &value),
                        .sub_assign => Value.sub(&current, &value),
                        .mul_assign => Value.mul(&current, &value),
                        .div_assign => Value.div(&current, &value),
                        .mod_assign => Value.mod(&current, &value),
                        .pow_assign => Value.pow(&current, &value),
                    };
                }

                try self.assignToExpr(a.target, value);
                return value;
            },

            .ternary => |t| {
                const cond = try self.evaluateExpression(t.condition);
                if (cond.isTruthy()) {
                    return self.evaluateExpression(t.true_expr);
                }
                return self.evaluateExpression(t.false_expr);
            },

            .function_call => |fc| {
                return self.callFunction(fc.name, fc.args);
            },

            .regex_match => |rm| {
                const string_val = try self.evaluateExpression(rm.string);
                const string_str = try string_val.asString(self.allocator);

                const pattern_str = switch (rm.pattern.kind) {
                    .regex_literal => |p| p,
                    else => blk: {
                        const p = try self.evaluateExpression(rm.pattern);
                        break :blk try p.asString(self.allocator);
                    },
                };

                const matches = self.matchRegex(string_str, pattern_str);
                const result = if (rm.negated) !matches else matches;
                return Value.initNumber(if (result) 1.0 else 0.0);
            },

            .in_expr => |ie| {
                const key = try self.evaluateExpression(ie.key);
                const key_str = try key.asString(self.allocator);

                if (self.arrays.get(ie.array)) |array| {
                    if (array.contains(key_str)) {
                        return Value.initNumber(1.0);
                    }
                }
                return Value.initNumber(0.0);
            },

            .getline => |gl| {
                return self.executeGetline(gl.var_name, gl.file, gl.pipe_cmd);
            },

            .concat => |c| {
                const left = try self.evaluateExpression(c.left);
                const right = try self.evaluateExpression(c.right);
                return left.concat(&right, self.allocator) catch Value.initEmpty();
            },
        }
    }

    fn assignToExpr(self: *Evaluator, target: *ast.Expression, value: Value) !void {
        switch (target.kind) {
            .variable => |name| {
                try self.setVariable(name, value);
            },
            .array_subscript => |as| {
                const key = try self.evaluateExpression(as.index);
                const key_str = try key.asString(self.allocator);
                try self.setArrayElement(as.array, key_str, value);
            },
            .field_ref => {
                // TODO: Setting field values
            },
            else => {},
        }
    }

    // safe-transpile: function uses raw slice parameter — consider safe.String
    fn setVariable(self: *Evaluator, name: []const u8, value: Value) !void {
        // Handle special variables
        if (safe.SimdUtils.eql(name, "FS")) {
            const str = try value.asString(self.allocator);
            self.field_separator = str;
            return;
        }
        if (safe.SimdUtils.eql(name, "OFS")) {
            const str = try value.asString(self.allocator);
            self.ofs = str;
            return;
        }
        if (safe.SimdUtils.eql(name, "ORS")) {
            const str = try value.asString(self.allocator);
            self.ors = str;
            return;
        }
        if (safe.SimdUtils.eql(name, "RS")) {
            const str = try value.asString(self.allocator);
            self.rs = str;
            return;
        }
        if (safe.SimdUtils.eql(name, "IGNORECASE")) {
            self.ignorecase = value.isTruthy();
            return;
        }
        if (safe.SimdUtils.eql(name, "NF")) {
            const new_nf = @as(usize, @intFromFloat(@max(0.0, value.asNumber())));
            if (new_nf < self.fields.items.len) {
                // Truncate fields and rebuild $0
                self.fields.items.len = new_nf;
                var new_line = std.ArrayListUnmanaged(u8){};
                errdefer new_line.deinit(self.allocator);
                // safe-transpile: for with index access requires manual review
                for (self.fields.items, 0..) |field, i| {
                    if (i > 0) try new_line.appendSlice(self.allocator, self.ofs);
                    try new_line.appendSlice(self.allocator, field);
                }
                const owned = try new_line.toOwnedSlice(self.allocator);
                self.current_line = owned;
                self.nf = new_nf;
            }
            return;
        }

        try self.variables.put(self.allocator, name, value);
    }

    // safe-transpile: function uses raw slice parameter — consider safe.String
    fn setArrayElement(self: *Evaluator, array_name: []const u8, key: []const u8, value: Value) !void {
        const result = try self.arrays.getOrPut(self.allocator, array_name);
        if (!result.found_existing) {
            result.value_ptr.* = .{};
        }
        try result.value_ptr.put(self.allocator, key, value);
    }

    fn isLeapYear(year: i64) bool {
        return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    }

    // safe-transpile: function uses raw slice parameter — consider safe.String
    fn callFunction(self: *Evaluator, name: []const u8, args: []*ast.Expression) !Value {
        // Built-in functions
        if (safe.SimdUtils.eql(name, "length")) {
            if (args.len == 0) {
                return Value.initNumber(@floatFromInt(self.current_line.len));
            }
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(val.length());
        }

        if (safe.SimdUtils.eql(name, "substr")) {
            if (args.len < 2) return Value.initEmpty();
            const str_val = try self.evaluateExpression(args[0]);
            const str = try str_val.asString(self.allocator);
            const start_val = try self.evaluateExpression(args[1]);
            const start_float = @max(1.0, start_val.asNumber());
            const start: usize = @as(usize, @intFromFloat(start_float)) -| 1;

            if (start >= str.len) return Value.initEmpty();

            var len = str.len - start;
            if (args.len >= 3) {
                const len_val = try self.evaluateExpression(args[2]);
                const len_float = @max(0.0, len_val.asNumber());
                len = @min(len, @as(usize, @intFromFloat(len_float)));
            }

            return Value.initString(str[start..@min(start + len, str.len)]);
        }

        if (safe.SimdUtils.eql(name, "index")) {
            if (args.len < 2) return Value.initNumber(0.0);
            const str_val = try self.evaluateExpression(args[0]);
            const str = try str_val.asString(self.allocator);
            const needle_val = try self.evaluateExpression(args[1]);
            const needle = try needle_val.asString(self.allocator);

            // zust: use safe.String or safe.GuardedSlice for slice operations
            if (std.mem.indexOf(u8, str, needle)) |pos| {
                return Value.initNumber(@floatFromInt(pos + 1));
            }
            return Value.initNumber(0.0);
        }

        if (safe.SimdUtils.eql(name, "split")) {
            if (args.len < 2) return Value.initNumber(0.0);
            const str_val = try self.evaluateExpression(args[0]);
            const str = try str_val.asString(self.allocator);

            // Get array name
            const array_name = switch (args[1].kind) {
                .variable => |n| n,
                else => return Value.initNumber(0.0),
            };

            var sep = self.field_separator;
            if (args.len >= 3) {
                const sep_val = try self.evaluateExpression(args[2]);
                sep = try sep_val.asString(self.allocator);
            }

            // Clear existing array
            if (self.arrays.getPtr(array_name)) |array| {
                var it = array.iterator();
                while (it.next()) |entry| {
                    var v = entry.value_ptr.*;
                    v.deinit();
                }
                array.clearAndFree(self.allocator);
            }

            // Split and store
            var count: usize = 0;
            if (sep.len == 1) {
                var iter = std.mem.splitScalar(u8, str, sep[0]);
                while (iter.next()) |part| {
                    count += 1;
                    const key = try std.fmt.allocPrint(self.allocator, "{d}", .{count});
                    // safe-transpile: free removed (memory owned by safe type);
                    const part_copy = try self.allocator.dupe(u8, part);
                    try self.setArrayElement(array_name, key, Value.initStringOwned(part_copy, self.allocator));
                }
            }

            return Value.initNumber(@floatFromInt(count));
        }

        if (safe.SimdUtils.eql(name, "toupper")) {
            if (args.len == 0) return Value.initEmpty();
            const val = try self.evaluateExpression(args[0]);
            const str = try val.asString(self.allocator);
            const upper = try self.allocator.alloc(u8, str.len);
            // safe-transpile: for with index access requires manual review
            for (str, 0..) |c, i| {
                upper[i] = std.ascii.toUpper(c);
            }
            return Value.initStringOwned(upper, self.allocator);
        }

        if (safe.SimdUtils.eql(name, "tolower")) {
            if (args.len == 0) return Value.initEmpty();
            const val = try self.evaluateExpression(args[0]);
            const str = try val.asString(self.allocator);
            const lower = try self.allocator.alloc(u8, str.len);
            // safe-transpile: for with index access requires manual review
            for (str, 0..) |c, i| {
                lower[i] = std.ascii.toLower(c);
            }
            return Value.initStringOwned(lower, self.allocator);
        }

        if (safe.SimdUtils.eql(name, "sprintf")) {
            // Basic sprintf - format first arg with remaining args
            if (args.len == 0) return Value.initEmpty();
            const format_val = try self.evaluateExpression(args[0]);
            const format_str = try format_val.asString(self.allocator);

            var result: std.ArrayListUnmanaged(u8) = .{};
            errdefer result.deinit(self.allocator);

            var arg_idx: usize = 1;
            var fmt_pos: usize = 0;
            while (fmt_pos < format_str.len) {
                if (format_str[fmt_pos] == '%' and fmt_pos + 1 < format_str.len) {
                    const spec = format_str[fmt_pos + 1];
                    switch (spec) {
                        '%' => try result.append(self.allocator, '%'),
                        's', 'S' => {
                            if (arg_idx < args.len) {
                                const arg_val = try self.evaluateExpression(args[arg_idx]);
                                const arg_str = try arg_val.asString(self.allocator);
                                try result.appendSlice(self.allocator, arg_str);
                                arg_idx += 1;
                            }
                        },
                        'd', 'D', 'i', 'I' => {
                            if (arg_idx < args.len) {
                                const arg_val = try self.evaluateExpression(args[arg_idx]);
                                const n = @as(i64, @intFromFloat(arg_val.asNumber()));
                                const str = try std.fmt.allocPrint(self.allocator, "{d}", .{n});
                                // safe-transpile: free removed (memory owned by safe type);
                                try result.appendSlice(self.allocator, str);
                                arg_idx += 1;
                            }
                        },
                        'f', 'F' => {
                            if (arg_idx < args.len) {
                                const arg_val = try self.evaluateExpression(args[arg_idx]);
                                const n = arg_val.asNumber();
                                const str = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{n});
                                // safe-transpile: free removed (memory owned by safe type);
                                try result.appendSlice(self.allocator, str);
                                arg_idx += 1;
                            }
                        },
                        'g', 'G' => {
                            if (arg_idx < args.len) {
                                const arg_val = try self.evaluateExpression(args[arg_idx]);
                                const n = arg_val.asNumber();
                                const str = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{n});
                                // safe-transpile: free removed (memory owned by safe type);
                                try result.appendSlice(self.allocator, str);
                                arg_idx += 1;
                            }
                        },
                        else => {
                            // Unknown format specifier, copy literally
                            try result.append(self.allocator, '%');
                            try result.append(self.allocator, spec);
                        },
                    }
                    fmt_pos += 2;
                } else {
                    try result.append(self.allocator, format_str[fmt_pos]);
                    fmt_pos += 1;
                }
            }

            const output = try result.toOwnedSlice(self.allocator);
            return Value.initStringOwned(output, self.allocator);
        }

        if (safe.SimdUtils.eql(name, "sin")) {
            if (args.len == 0) return Value.initNumber(0.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@sin(val.asNumber()));
        }

        if (safe.SimdUtils.eql(name, "cos")) {
            if (args.len == 0) return Value.initNumber(1.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@cos(val.asNumber()));
        }

        if (safe.SimdUtils.eql(name, "sqrt")) {
            if (args.len == 0) return Value.initNumber(0.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@sqrt(val.asNumber()));
        }

        if (safe.SimdUtils.eql(name, "int")) {
            if (args.len == 0) return Value.initNumber(0.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@trunc(val.asNumber()));
        }

        if (safe.SimdUtils.eql(name, "log")) {
            if (args.len == 0) return Value.initNumber(0.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@log(val.asNumber()));
        }

        if (safe.SimdUtils.eql(name, "exp")) {
            if (args.len == 0) return Value.initNumber(1.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@exp(val.asNumber()));
        }

        if (safe.SimdUtils.eql(name, "gensub")) {
            // gensub(pattern, replacement, how [, target])
            if (args.len < 3) return Value.initString("");
            // For regex literals, get the pattern string directly (not the match result)
            const pat_str = switch (args[0].kind) {
                .regex_literal => |p| p,
                else => blk: {
                    const pat_val = try self.evaluateExpression(args[0]);
                    break :blk try pat_val.asString(self.allocator);
                },
            };
            const repl_val = try self.evaluateExpression(args[1]);
            const repl_str = try repl_val.asString(self.allocator);
            const how_val = try self.evaluateExpression(args[2]);
            const how_str = try how_val.asString(self.allocator);

            var target = self.current_line;
            if (args.len >= 4) {
                const target_val = try self.evaluateExpression(args[3]);
                target = try target_val.asString(self.allocator);
            }

            const global = how_str.len > 0 and (how_str[0] == 'g' or how_str[0] == 'G');
            const which_match = if (!global) @as(usize, @intFromFloat(@max(0.0, how_val.asNumber()))) else 0;

            var result: std.ArrayListUnmanaged(u8) = .{};
            errdefer result.deinit(self.allocator);

            var pos: usize = 0;
            var match_count: usize = 0;

            var early_break = false;
            while (pos <= target.len) {
                // Use simple literal matching for now (regex engine findAll has issues)
                const match_start = if (self.ignorecase)
                    std.ascii.indexOfIgnoreCasePos(target, pos, pat_str)
                else
                    std.mem.indexOfPos(u8, target, pos, pat_str);
                if (match_start) |ms| {
                    match_count += 1;
                    const match_end = ms + pat_str.len;

                    if (global or match_count == which_match) {
                        // Copy text before match
                        try result.appendSlice(self.allocator, target[pos..ms]);

                        // Apply replacement with & and \0
                        var ri: usize = 0;
                        while (ri < repl_str.len) : (ri += 1) {
                            if (repl_str[ri] == '&' and (ri == 0 or repl_str[ri - 1] != '\\')) {
                                try result.appendSlice(self.allocator, target[ms..match_end]);
                            } else if (repl_str[ri] == '\\' and ri + 1 < repl_str.len) {
                                ri += 1;
                                const esc = repl_str[ri];
                                if (esc == '&') {
                                    try result.append(self.allocator, '&');
                                } else if (esc == '\\') {
                                    try result.append(self.allocator, '\\');
                                } else {
                                    try result.append(self.allocator, '\\');
                                    try result.append(self.allocator, esc);
                                }
                            } else {
                                try result.append(self.allocator, repl_str[ri]);
                            }
                        }

                        pos = match_end;
                        if (!global) {
                            early_break = true;
                            break;
                        }
                    } else {
                        // Not the match we want, copy it through
                        try result.appendSlice(self.allocator, target[pos..match_end]);
                        pos = match_end;
                    }
                } else {
                    // No more matches
                    try result.appendSlice(self.allocator, target[pos..]);
                    break;
                }
            }
            // Append remaining text only after early break
            if (early_break) {
                try result.appendSlice(self.allocator, target[pos..]);
            }

            const output = try result.toOwnedSlice(self.allocator);
            return Value.initStringOwned(output, self.allocator);
        }

        if (safe.SimdUtils.eql(name, "gsub") or safe.SimdUtils.eql(name, "sub")) {
            const is_gsub = safe.SimdUtils.eql(name, "gsub");
            if (args.len < 2) return Value.initNumber(0.0);
            const pat_str = switch (args[0].kind) {
                .regex_literal => |p| p,
                else => blk: {
                    const pat_val = try self.evaluateExpression(args[0]);
                    break :blk try pat_val.asString(self.allocator);
                },
            };
            const repl_val = try self.evaluateExpression(args[1]);
            const repl_str = try repl_val.asString(self.allocator);

            // Target: optional third arg, or $0
            const target_expr = if (args.len >= 3) args[2] else null;
            const target_name = if (target_expr) |te| switch (te.kind) {
                .variable => |n| n,
                else => null,
            } else null;

            var target = if (target_expr) |te| try (try self.evaluateExpression(te)).asString(self.allocator) else self.current_line;

            var result: std.ArrayListUnmanaged(u8) = .{};
            errdefer result.deinit(self.allocator);

            var pos: usize = 0;
            var match_count: usize = 0;
            var early_break = false;
            while (pos <= target.len) {
                const match_start = if (self.ignorecase)
                    std.ascii.indexOfIgnoreCasePos(target, pos, pat_str)
                else
                    std.mem.indexOfPos(u8, target, pos, pat_str);
                if (match_start) |ms| {
                    match_count += 1;
                    const match_end = ms + pat_str.len;
                    try result.appendSlice(self.allocator, target[pos..ms]);
                    // Apply replacement with & and \
                    var ri: usize = 0;
                    while (ri < repl_str.len) : (ri += 1) {
                        if (repl_str[ri] == '&' and (ri == 0 or repl_str[ri - 1] != '\\')) {
                            try result.appendSlice(self.allocator, target[ms..match_end]);
                        } else if (repl_str[ri] == '\\' and ri + 1 < repl_str.len) {
                            ri += 1;
                            const esc = repl_str[ri];
                            if (esc == '&') {
                                try result.append(self.allocator, '&');
                            } else if (esc == '\\') {
                                try result.append(self.allocator, '\\');
                            } else {
                                try result.append(self.allocator, '\\');
                                try result.append(self.allocator, esc);
                            }
                        } else {
                            try result.append(self.allocator, repl_str[ri]);
                        }
                    }
                    pos = match_end;
                    if (!is_gsub) {
                        early_break = true;
                        break;
                    }
                } else {
                    try result.appendSlice(self.allocator, target[pos..]);
                    break;
                }
            }
            if (early_break) {
                try result.appendSlice(self.allocator, target[pos..]);
            }

            const output = try result.toOwnedSlice(self.allocator);
            if (target_expr != null) {
                if (target_name) |tn| {
                    try self.setVariable(tn, Value.initStringOwned(output, self.allocator));
                } else {
                    // For non-variable targets (like $1), need to handle differently
                    // safe-transpile: free removed (memory owned by safe type);
                }
            } else {
                // Modify $0
                self.setCurrentLine(output);
            }
            return Value.initNumber(@floatFromInt(match_count));
        }

        if (safe.SimdUtils.eql(name, "match")) {
            // match(string, pattern [, array])
            if (args.len < 2) return Value.initNumber(0.0);
            const str_val = try self.evaluateExpression(args[0]);
            const str = try str_val.asString(self.allocator);
            const pat_str = switch (args[1].kind) {
                .regex_literal => |p| p,
                else => blk: {
                    const pat_val = try self.evaluateExpression(args[1]);
                    break :blk try pat_val.asString(self.allocator);
                },
            };

            // Literal matching (regex engine findAll has state issues with iteration)
            const pos = if (self.ignorecase)
                std.ascii.indexOfIgnoreCase(str, pat_str)
            else
                // zust: use safe.String or safe.GuardedSlice for slice operations
                std.mem.indexOf(u8, str, pat_str);
            if (pos) |p| {
                self.rstart = p + 1; // 1-based
                // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
                self.rlength = @intCast(pat_str.len);

                // Optional array argument for capture groups
                if (args.len >= 3) {
                    const array_name = switch (args[2].kind) {
                        .variable => |n| n,
                        else => null,
                    };
                    if (array_name) |aname| {
                        // Clear array
                        if (self.arrays.getPtr(aname)) |array| {
                            var it = array.iterator();
                            while (it.next()) |entry| {
                                var v = entry.value_ptr.*;
                                v.deinit();
                            }
                            array.clearAndFree(self.allocator);
                        }
                        // Store matched text
                        const key0 = try self.allocator.dupe(u8, "0");
                        const val0 = try self.allocator.dupe(u8, str[p .. p + pat_str.len]);
                        try self.setArrayElement(aname, key0, Value.initStringOwned(val0, self.allocator));
                        // Store start position
                        const start_key = try self.allocator.dupe(u8, "start,0");
                        const start_val = try std.fmt.allocPrint(self.allocator, "{d}", .{p + 1});
                        try self.setArrayElement(aname, start_key, Value.initStringOwned(start_val, self.allocator));
                        // Store length
                        const len_key = try self.allocator.dupe(u8, "length,0");
                        const len_val = try std.fmt.allocPrint(self.allocator, "{d}", .{pat_str.len});
                        try self.setArrayElement(aname, len_key, Value.initStringOwned(len_val, self.allocator));
                    }
                }

                return Value.initNumber(@floatFromInt(p + 1));
            } else {
                self.rstart = 0;
                self.rlength = -1;
                return Value.initNumber(0.0);
            }
        }

        if (safe.SimdUtils.eql(name, "systime")) {
            const now = std.time.timestamp();
            return Value.initNumber(@floatFromInt(now));
        }

        if (safe.SimdUtils.eql(name, "strftime")) {
            // strftime([format [, timestamp]])
            var format_str: safe.Slice(u8) = "%Y-%m-%d %H:%M:%S";
            var timestamp: i64 = std.time.timestamp();
            if (args.len > 0) {
                const fmt_val = try self.evaluateExpression(args[0]);
                format_str = try fmt_val.asString(self.allocator);
            }
            if (args.len > 1) {
                const time_val = try self.evaluateExpression(args[1]);
                timestamp = @intFromFloat(time_val.asNumber());
            }

            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
            const epoch_day = epoch.getEpochDay();
            const year_day = epoch_day.calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const day_secs = epoch.getDaySeconds();

            var result: std.ArrayListUnmanaged(u8) = .{};
            errdefer result.deinit(self.allocator);

            var i: usize = 0;
            while (i < format_str.len) : (i += 1) {
                if (format_str[i] == '%' and i + 1 < format_str.len) {
                    i += 1;
                    switch (format_str[i]) {
                        '%' => try result.append(self.allocator, '%'),
                        'Y' => {
                            const str = try std.fmt.allocPrint(self.allocator, "{d}", .{year_day.year});
                            // safe-transpile: free removed (memory owned by safe type);
                            try result.appendSlice(self.allocator, str);
                        },
                        'y' => {
                            const short_year = @mod(year_day.year, 100);
                            const str = try std.fmt.allocPrint(self.allocator, "{d:0>2}", .{short_year});
                            // safe-transpile: free removed (memory owned by safe type);
                            try result.appendSlice(self.allocator, str);
                        },
                        'm' => {
                            const str = try std.fmt.allocPrint(self.allocator, "{d:0>2}", .{month_day.month});
                            // safe-transpile: free removed (memory owned by safe type);
                            try result.appendSlice(self.allocator, str);
                        },
                        'd' => {
                            const str = try std.fmt.allocPrint(self.allocator, "{d:0>2}", .{month_day.day_index + 1});
                            // safe-transpile: free removed (memory owned by safe type);
                            try result.appendSlice(self.allocator, str);
                        },
                        'H' => {
                            const str = try std.fmt.allocPrint(self.allocator, "{d:0>2}", .{day_secs.getHoursIntoDay()});
                            // safe-transpile: free removed (memory owned by safe type);
                            try result.appendSlice(self.allocator, str);
                        },
                        'M' => {
                            const str = try std.fmt.allocPrint(self.allocator, "{d:0>2}", .{day_secs.getMinutesIntoHour()});
                            // safe-transpile: free removed (memory owned by safe type);
                            try result.appendSlice(self.allocator, str);
                        },
                        'S' => {
                            const str = try std.fmt.allocPrint(self.allocator, "{d:0>2}", .{day_secs.getSecondsIntoMinute()});
                            // safe-transpile: free removed (memory owned by safe type);
                            try result.appendSlice(self.allocator, str);
                        },
                        's' => {
                            const str = try std.fmt.allocPrint(self.allocator, "{d}", .{timestamp});
                            // safe-transpile: free removed (memory owned by safe type);
                            try result.appendSlice(self.allocator, str);
                        },
                        else => {
                            try result.append(self.allocator, '%');
                            try result.append(self.allocator, format_str[i]);
                        },
                    }
                } else {
                    try result.append(self.allocator, format_str[i]);
                }
            }

            const output = try result.toOwnedSlice(self.allocator);
            return Value.initStringOwned(output, self.allocator);
        }

        if (safe.SimdUtils.eql(name, "mktime")) {
            // mktime("YYYY MM DD HH MM SS [DST]") -> timestamp
            if (args.len == 0) return Value.initNumber(-1.0);
            const val = try self.evaluateExpression(args[0]);
            const datespec = try val.asString(self.allocator);
            // Parse "YYYY MM DD HH MM SS"
            var parts: [6]i64 = .{};
            var part_idx: usize = 0;
            var iter = std.mem.splitScalar(u8, datespec, ' ');
            while (iter.next()) |part| {
                if (part_idx < 6) {
                    parts[part_idx] = std.fmt.parseInt(i64, part, 10) catch 0;
                    part_idx += 1;
                }
            }
            if (part_idx < 6) return Value.initNumber(-1.0);

            // Convert to epoch seconds (simplified: assumes UTC)
            const year = parts[0];
            const month = parts[1];
            const day = parts[2];
            const hour = parts[3];
            const minute = parts[4];
            const second = parts[5];

            // Days from 1970 to year-01-01
            var days: i64 = 0;
            var y: i64 = 1970;
            while (y < year) : (y += 1) {
                days += if (isLeapYear(y)) 366 else 365;
            }
            // Days from year-01-01 to year-month-01
            const month_days = [_]i64{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
            var m: i64 = 1;
            while (m < month) : (m += 1) {
                // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
                days += month_days[@intCast(m)];
                if (m == 2 and isLeapYear(year)) days += 1;
            }
            // Days in month
            days += day - 1;

            const timestamp = days * std.time.s_per_day + hour * std.time.s_per_hour + minute * std.time.s_per_min + second;
            return Value.initNumber(@floatFromInt(timestamp));
        }

        if (safe.SimdUtils.eql(name, "asort") or safe.SimdUtils.eql(name, "asorti")) {
            const is_asorti = safe.SimdUtils.eql(name, "asorti");
            if (args.len == 0) return Value.initNumber(0.0);

            // Get source array name
            const src_name = switch (args[0].kind) {
                .variable => |n| n,
                else => return Value.initNumber(0.0),
            };

            // Get optional destination array name (defaults to source)
            var dest_name = src_name;
            if (args.len >= 2) {
                dest_name = switch (args[1].kind) {
                    .variable => |n| n,
                    else => return Value.initNumber(0.0),
                };
            }

            const ArrayItem = struct { key: []const u8, val: Value };

            // Collect items from source array
            var items = std.ArrayListUnmanaged(ArrayItem){};
            defer {
                for (0..items.items.len) |__zust_i| {
                    const item = &items.items[__zust_i];
                    self.allocator.free(item.key);
                }
                items.deinit(self.allocator);
            }

            if (self.arrays.get(src_name)) |src_array| {
                var it = src_array.iterator();
                while (it.next()) |entry| {
                    const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
                    const val_copy = try entry.value_ptr.*.clone(self.allocator);
                    try items.append(self.allocator, .{ .key = key_copy, .val = val_copy });
                }
            }

            // Sort
            const SortCtx = struct {
                allocator: std.mem.Allocator,
                is_asorti: bool,
                pub fn lessThan(ctx: @This(), a: ArrayItem, b: ArrayItem) bool {
                    if (ctx.is_asorti) {
                        return std.mem.lessThan(u8, a.key, b.key);
                    } else {
                        const a_str = a.val.asString(ctx.allocator) catch "";
                        // safe-transpile: free removed (memory owned by safe type);
                        const b_str = b.val.asString(ctx.allocator) catch "";
                        // safe-transpile: free removed (memory owned by safe type);
                        return std.mem.lessThan(u8, a_str, b_str);
                    }
                }
            };
            std.mem.sort(ArrayItem, items.items, SortCtx{ .allocator = self.allocator, .is_asorti = is_asorti }, SortCtx.lessThan);

            // Clear destination array
            if (self.arrays.getPtr(dest_name)) |array| {
                var it = array.iterator();
                while (it.next()) |entry| {
                    var v = entry.value_ptr.*;
                    v.deinit();
                }
                array.clearAndFree(self.allocator);
            }

            // Write sorted items to destination array with 1-based indices
            // safe-transpile: for with index access requires manual review
            for (items.items, 0..) |item, i| {
                const idx = i + 1;
                const key_str = try std.fmt.allocPrint(self.allocator, "{d}", .{idx});
                // safe-transpile: free removed (memory owned by safe type);
                if (is_asorti) {
                    const val_copy = try self.allocator.dupe(u8, item.key);
                    try self.setArrayElement(dest_name, key_str, Value.initStringOwned(val_copy, self.allocator));
                } else {
                    try self.setArrayElement(dest_name, key_str, item.val);
                }
            }

            return Value.initNumber(@floatFromInt(items.items.len));
        }

        // Bitwise functions
        if (safe.SimdUtils.eql(name, "and") or safe.SimdUtils.eql(name, "or") or safe.SimdUtils.eql(name, "xor")) {
            if (args.len < 2) return Value.initNumber(0.0);
            var result: i64 = @as(i64, @intFromFloat((try self.evaluateExpression(args[0])).asNumber()));
            for (args[1..]) |arg| {
                const val: i64 = @as(i64, @intFromFloat((try self.evaluateExpression(arg)).asNumber()));
                if (safe.SimdUtils.eql(name, "and")) {
                    result &= val;
                } else if (safe.SimdUtils.eql(name, "or")) {
                    result |= val;
                } else {
                    result ^= val;
                }
            }
            return Value.initNumber(@floatFromInt(result));
        }

        if (safe.SimdUtils.eql(name, "compl")) {
            if (args.len == 0) return Value.initNumber(0.0);
            const val: i64 = @as(i64, @intFromFloat((try self.evaluateExpression(args[0])).asNumber()));
            return Value.initNumber(@floatFromInt(~val));
        }

        if (safe.SimdUtils.eql(name, "lshift")) {
            if (args.len < 2) return Value.initNumber(0.0);
            const val: i64 = @as(i64, @intFromFloat((try self.evaluateExpression(args[0])).asNumber()));
            const count: i64 = @as(i64, @intFromFloat((try self.evaluateExpression(args[1])).asNumber()));
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            return Value.initNumber(@floatFromInt(val << @intCast(count)));
        }

        if (safe.SimdUtils.eql(name, "rshift")) {
            if (args.len < 2) return Value.initNumber(0.0);
            const val: i64 = @as(i64, @intFromFloat((try self.evaluateExpression(args[0])).asNumber()));
            const count: i64 = @as(i64, @intFromFloat((try self.evaluateExpression(args[1])).asNumber()));
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            return Value.initNumber(@floatFromInt(val >> @intCast(count)));
        }

        if (safe.SimdUtils.eql(name, "typeof")) {
            if (args.len == 0) return Value.initString("unassigned");
            const val = try self.evaluateExpression(args[0]);
            if (val.flags.has_string) {
                return Value.initString("string");
            }
            if (val.flags.has_number) return Value.initString("number");
            return Value.initString("unassigned");
        }

        // User-defined function
        if (self.functions.get(name)) |func| {
            // Save current variables (simple scoping)
            var saved_vars = std.StringHashMapUnmanaged(Value){};
            defer saved_vars.deinit(self.allocator);

            // Bind parameters
            // safe-transpile: for with index access requires manual review
            for (func.params, 0..) |param, i| {
                if (self.variables.get(param)) |existing| {
                    try saved_vars.put(self.allocator, param, existing);
                }
                if (i < args.len) {
                    const arg_val = try self.evaluateExpression(args[i]);
                    try self.setVariable(param, arg_val);
                } else {
                    try self.setVariable(param, Value.initEmpty());
                }
            }

            // Execute function body
            try self.executeStatement(func.body);

            // Get return value
            const result = self.return_value;
            self.return_value = Value.initEmpty();
            self.control = .normal;

            // Restore variables
            for (func.params) |param| {
                _ = self.variables.remove(param);
            }
            var it = saved_vars.iterator();
            while (it.next()) |entry| {
                try self.variables.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
            }

            return result;
        }

        return EvalError.UndefinedFunction;
    }

    // safe-transpile: function uses raw slice parameter — consider safe.String
    fn matchRegex(self: *Evaluator, text: []const u8, pattern: []const u8) bool {
        if (self.ignorecase) {
            // Case-insensitive literal matching
            return std.ascii.indexOfIgnoreCase(text, pattern) != null;
        }
        // zust: use safe.String or safe.GuardedSlice for slice operations
        return std.mem.indexOf(u8, text, pattern) != null;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Evaluator: simple print" {
    const allocator = std.testing.allocator;

    var p = parser.Parser.init("{ print $1 }", allocator);
    var program = try p.parse();
    defer program.deinit();

    var eval = Evaluator.init(allocator, &program.functions);
    defer eval.deinit();

    const output = try eval.execute(&program, "hello world", null, true);
    // safe-transpile: free removed (memory owned by safe type);

    try std.testing.expectEqualStrings("hello\n", output);
}

test "Evaluator: arithmetic expression" {
    const allocator = std.testing.allocator;

    var p = parser.Parser.init("BEGIN { print 2 + 3 * 4 }", allocator);
    var program = try p.parse();
    defer program.deinit();

    var eval = Evaluator.init(allocator, &program.functions);
    defer eval.deinit();

    const output = try eval.execute(&program, "", null, true);
    // safe-transpile: free removed (memory owned by safe type);

    try std.testing.expectEqualStrings("14\n", output);
}

test "Evaluator: variable assignment" {
    const allocator = std.testing.allocator;

    var p = parser.Parser.init("BEGIN { x = 5; print x }", allocator);
    var program = try p.parse();
    defer program.deinit();

    var eval = Evaluator.init(allocator, &program.functions);
    defer eval.deinit();

    const output = try eval.execute(&program, "", null, true);
    // safe-transpile: free removed (memory owned by safe type);

    try std.testing.expectEqualStrings("5\n", output);
}
