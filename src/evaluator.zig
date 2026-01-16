const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;
const parser = @import("parser.zig");

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

    /// Field separator
    field_separator: []const u8 = " \t",

    /// Output field separator
    ofs: []const u8 = " ",

    /// Output record separator
    ors: []const u8 = "\n",

    /// Line number (NR)
    nr: u64 = 0,

    /// File line number (FNR)
    fnr: u64 = 0,

    /// Number of fields in current line (NF)
    nf: u64 = 0,

    /// Current filename
    filename: []const u8 = "",

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
        return .{
            .allocator = allocator,
            .variables = .{},
            .arrays = .{},
            .functions = functions,
            .output = .{},
        };
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

        if (self.return_value.flags.string_owned) {
            self.return_value.deinit();
        }
    }

    /// Execute a complete AWK program
    pub fn execute(self: *Evaluator, program: *ast.Program, input: []const u8) ![]const u8 {
        // Execute BEGIN block
        if (program.begin) |begin| {
            try self.executeStatement(begin);
            if (self.control == .exit_program) {
                return try self.output.toOwnedSlice(self.allocator);
            }
            self.control = .normal;
        }

        // Process each input line
        var line_iter = std.mem.splitScalar(u8, input, '\n');
        while (line_iter.next()) |line| {
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

                if (self.control == .next_line) {
                    self.control = .normal;
                    break;
                }
                if (self.control == .exit_program) {
                    break;
                }
            }

            if (self.control == .exit_program) break;
        }

        // Execute END block
        if (program.end) |end| {
            self.control = .normal;
            try self.executeStatement(end);
        }

        return try self.output.toOwnedSlice(self.allocator);
    }

    fn setCurrentLine(self: *Evaluator, line: []const u8) void {
        self.current_line = line;
        self.fields.clearRetainingCapacity();

        // Split line into fields
        if (std.mem.eql(u8, self.field_separator, " \t")) {
            // Default: split on whitespace, collapse multiple spaces
            var in_field = false;
            var field_start: usize = 0;

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
                for (stmts) |*s| {
                    var inner_stmt = s.*;
                    try self.executeStatement(&inner_stmt);
                    if (self.control != .normal) return;
                }
            },

            .expression => |expr| {
                _ = try self.evaluateExpression(expr);
            },

            .print => |p| {
                try self.executePrint(p.args, p.output_file, p.append);
            },

            .printf => |pf| {
                try self.executePrintf(pf.format, pf.args, pf.output_file, pf.append);
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

            .getline_stmt => |_| {
                // TODO: Implement getline
            },

            .empty => {},
        }
    }

    fn executePrint(self: *Evaluator, args: []*ast.Expression, output_file: ?*ast.Expression, _: bool) !void {
        _ = output_file; // TODO: Support file output

        if (args.len == 0) {
            // print $0
            try self.output.appendSlice(self.allocator,self.current_line);
        } else {
            for (args, 0..) |arg, i| {
                if (i > 0) try self.output.appendSlice(self.allocator,self.ofs);
                const val = try self.evaluateExpression(arg);
                const str = try val.asString(self.allocator);
                try self.output.appendSlice(self.allocator,str);
            }
        }
        try self.output.appendSlice(self.allocator,self.ors);
    }

    fn executePrintf(self: *Evaluator, format_expr: *ast.Expression, args: []*ast.Expression, output_file: ?*ast.Expression, _: bool) !void {
        _ = output_file; // TODO: Support file output

        const format_val = try self.evaluateExpression(format_expr);
        const format_str = try format_val.asString(self.allocator);

        // Simple printf implementation
        var arg_idx: usize = 0;
        var i: usize = 0;
        while (i < format_str.len) {
            if (format_str[i] == '%' and i + 1 < format_str.len) {
                i += 1;
                if (format_str[i] == '%') {
                    try self.output.append(self.allocator,'%');
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
                            defer self.allocator.free(formatted);
                            try self.output.appendSlice(self.allocator,formatted);
                        },
                        'f', 'e', 'g' => {
                            const formatted = try std.fmt.allocPrint(self.allocator, "{d:.6}", .{val.asNumber()});
                            defer self.allocator.free(formatted);
                            try self.output.appendSlice(self.allocator,formatted);
                        },
                        's' => {
                            const str = try val.asString(self.allocator);
                            try self.output.appendSlice(self.allocator,str);
                        },
                        'c' => {
                            const n: u8 = @intFromFloat(val.asNumber());
                            try self.output.append(self.allocator,n);
                        },
                        else => {},
                    }
                }
            } else {
                // Handle escape sequences
                if (format_str[i] == '\\' and i + 1 < format_str.len) {
                    i += 1;
                    switch (format_str[i]) {
                        'n' => try self.output.append(self.allocator,'\n'),
                        't' => try self.output.append(self.allocator,'\t'),
                        'r' => try self.output.append(self.allocator,'\r'),
                        '\\' => try self.output.append(self.allocator,'\\'),
                        else => {
                            try self.output.append(self.allocator,'\\');
                            try self.output.append(self.allocator,format_str[i]);
                        },
                    }
                    i += 1;
                } else {
                    try self.output.append(self.allocator,format_str[i]);
                    i += 1;
                }
            }
        }
    }

    fn evaluateExpression(self: *Evaluator, expr: *ast.Expression) EvalError!Value {
        switch (expr.kind) {
            .number_literal => |n| return Value.initNumber(n),

            .string_literal => |s| return Value.initString(s),

            .regex_literal => |pattern| {
                // When used as expression, match against $0
                if (matchRegex(self.current_line, pattern)) {
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
                if (std.mem.eql(u8, name, "NR")) return Value.initNumber(@floatFromInt(self.nr));
                if (std.mem.eql(u8, name, "NF")) return Value.initNumber(@floatFromInt(self.nf));
                if (std.mem.eql(u8, name, "FNR")) return Value.initNumber(@floatFromInt(self.fnr));
                if (std.mem.eql(u8, name, "FS")) return Value.initString(self.field_separator);
                if (std.mem.eql(u8, name, "OFS")) return Value.initString(self.ofs);
                if (std.mem.eql(u8, name, "ORS")) return Value.initString(self.ors);
                if (std.mem.eql(u8, name, "FILENAME")) return Value.initString(self.filename);

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

                const matches = matchRegex(string_str, pattern_str);
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

            .getline => |_| {
                // TODO: Implement getline expression
                return Value.initNumber(0.0);
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
            .field_ref => |_| {
                // TODO: Setting field values
            },
            else => {},
        }
    }

    fn setVariable(self: *Evaluator, name: []const u8, value: Value) !void {
        // Handle special variables
        if (std.mem.eql(u8, name, "FS")) {
            const str = try value.asString(self.allocator);
            self.field_separator = str;
            return;
        }
        if (std.mem.eql(u8, name, "OFS")) {
            const str = try value.asString(self.allocator);
            self.ofs = str;
            return;
        }
        if (std.mem.eql(u8, name, "ORS")) {
            const str = try value.asString(self.allocator);
            self.ors = str;
            return;
        }

        try self.variables.put(self.allocator, name, value);
    }

    fn setArrayElement(self: *Evaluator, array_name: []const u8, key: []const u8, value: Value) !void {
        const result = try self.arrays.getOrPut(self.allocator, array_name);
        if (!result.found_existing) {
            result.value_ptr.* = .{};
        }
        try result.value_ptr.put(self.allocator, key, value);
    }

    fn callFunction(self: *Evaluator, name: []const u8, args: []*ast.Expression) !Value {
        // Built-in functions
        if (std.mem.eql(u8, name, "length")) {
            if (args.len == 0) {
                return Value.initNumber(@floatFromInt(self.current_line.len));
            }
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(val.length());
        }

        if (std.mem.eql(u8, name, "substr")) {
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

        if (std.mem.eql(u8, name, "index")) {
            if (args.len < 2) return Value.initNumber(0.0);
            const str_val = try self.evaluateExpression(args[0]);
            const str = try str_val.asString(self.allocator);
            const needle_val = try self.evaluateExpression(args[1]);
            const needle = try needle_val.asString(self.allocator);

            if (std.mem.indexOf(u8, str, needle)) |pos| {
                return Value.initNumber(@floatFromInt(pos + 1));
            }
            return Value.initNumber(0.0);
        }

        if (std.mem.eql(u8, name, "split")) {
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
                    defer self.allocator.free(key);
                    try self.setArrayElement(array_name, key, Value.initString(part));
                }
            }

            return Value.initNumber(@floatFromInt(count));
        }

        if (std.mem.eql(u8, name, "toupper")) {
            if (args.len == 0) return Value.initEmpty();
            const val = try self.evaluateExpression(args[0]);
            const str = try val.asString(self.allocator);
            const upper = try self.allocator.alloc(u8, str.len);
            for (str, 0..) |c, i| {
                upper[i] = std.ascii.toUpper(c);
            }
            return Value.initStringOwned(upper, self.allocator);
        }

        if (std.mem.eql(u8, name, "tolower")) {
            if (args.len == 0) return Value.initEmpty();
            const val = try self.evaluateExpression(args[0]);
            const str = try val.asString(self.allocator);
            const lower = try self.allocator.alloc(u8, str.len);
            for (str, 0..) |c, i| {
                lower[i] = std.ascii.toLower(c);
            }
            return Value.initStringOwned(lower, self.allocator);
        }

        if (std.mem.eql(u8, name, "sprintf")) {
            // Basic sprintf - format first arg with remaining args
            if (args.len == 0) return Value.initEmpty();
            // TODO: Implement full sprintf
            const format_val = try self.evaluateExpression(args[0]);
            return format_val;
        }

        if (std.mem.eql(u8, name, "sin")) {
            if (args.len == 0) return Value.initNumber(0.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@sin(val.asNumber()));
        }

        if (std.mem.eql(u8, name, "cos")) {
            if (args.len == 0) return Value.initNumber(1.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@cos(val.asNumber()));
        }

        if (std.mem.eql(u8, name, "sqrt")) {
            if (args.len == 0) return Value.initNumber(0.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@sqrt(val.asNumber()));
        }

        if (std.mem.eql(u8, name, "int")) {
            if (args.len == 0) return Value.initNumber(0.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@trunc(val.asNumber()));
        }

        if (std.mem.eql(u8, name, "log")) {
            if (args.len == 0) return Value.initNumber(0.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@log(val.asNumber()));
        }

        if (std.mem.eql(u8, name, "exp")) {
            if (args.len == 0) return Value.initNumber(1.0);
            const val = try self.evaluateExpression(args[0]);
            return Value.initNumber(@exp(val.asNumber()));
        }

        // User-defined function
        if (self.functions.get(name)) |func| {
            // Save current variables (simple scoping)
            var saved_vars = std.StringHashMapUnmanaged(Value){};
            defer saved_vars.deinit(self.allocator);

            // Bind parameters
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

    fn matchRegex(text: []const u8, pattern: []const u8) bool {
        // Simple literal matching for now
        // TODO: Use regex library
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

    const output = try eval.execute(&program, "hello world");
    defer allocator.free(output);

    try std.testing.expectEqualStrings("hello\n", output);
}

test "Evaluator: arithmetic expression" {
    const allocator = std.testing.allocator;

    var p = parser.Parser.init("BEGIN { print 2 + 3 * 4 }", allocator);
    var program = try p.parse();
    defer program.deinit();

    var eval = Evaluator.init(allocator, &program.functions);
    defer eval.deinit();

    const output = try eval.execute(&program, "");
    defer allocator.free(output);

    try std.testing.expectEqualStrings("14\n", output);
}

test "Evaluator: variable assignment" {
    const allocator = std.testing.allocator;

    var p = parser.Parser.init("BEGIN { x = 5; print x }", allocator);
    var program = try p.parse();
    defer program.deinit();

    var eval = Evaluator.init(allocator, &program.functions);
    defer eval.deinit();

    const output = try eval.execute(&program, "");
    defer allocator.free(output);

    try std.testing.expectEqualStrings("5\n", output);
}
