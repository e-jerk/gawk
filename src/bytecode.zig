const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;

// ============================================================================
// AWK Bytecode VM - GPU-Compatible Instruction Set
// ============================================================================
//
// This bytecode format is designed to execute AWK programs on GPU compute shaders.
// Each GPU thread processes one input line independently.
//
// Key design decisions:
// - Fixed-size instructions (4 bytes) for aligned GPU memory access
// - Stack-based evaluation (simple, GPU-friendly)
// - Bounded loops (GPU doesn't support infinite loops)
// - Per-thread local variables (no inter-thread communication during line processing)
// - Global accumulation handled by atomic operations or CPU post-processing
//
// ============================================================================

/// Bytecode opcodes - each fits in 1 byte
pub const Opcode = enum(u8) {
    // Stack operations
    nop = 0,
    push_num = 1, // Push number constant (arg1:arg2 = constant index)
    push_str = 2, // Push string constant (arg1:arg2 = constant index)
    push_field = 3, // Push field value (arg1 = field number, 0 = $0)
    push_var = 4, // Push variable (arg1 = variable index)
    push_special = 5, // Push special variable (arg1 = special var type: NR, NF, etc.)
    pop = 6, // Discard top of stack
    dup = 7, // Duplicate top of stack

    // Arithmetic operations (operate on top 2 stack values)
    add = 10,
    sub = 11,
    mul = 12,
    div = 13,
    mod = 14,
    pow = 15,
    neg = 16, // Unary negation

    // Comparison operations (push 1 or 0)
    lt = 20,
    le = 21,
    gt = 22,
    ge = 23,
    eq = 24,
    ne = 25,

    // Logical operations
    @"and" = 30,
    @"or" = 31,
    not = 32,

    // String operations
    concat = 40, // Concatenate top 2 strings
    length = 41, // Push length of top string
    substr = 42, // substr(str, start, len) - 3 args
    index_fn = 43, // index(str, needle) - 2 args
    toupper = 44, // Convert to uppercase
    tolower = 45, // Convert to lowercase
    split_fn = 46, // split(str, array, sep) - returns count

    // Math functions (operate on top of stack)
    sin = 50,
    cos = 51,
    sqrt = 52,
    int_fn = 53, // Truncate to integer
    log_fn = 54,
    exp_fn = 55,
    atan2 = 56, // 2 args
    rand_fn = 57,
    srand = 58,

    // Control flow
    jmp = 60, // Jump to address (arg1:arg2 = offset)
    jmp_if = 61, // Jump if top of stack is truthy
    jmp_if_not = 62, // Jump if top of stack is falsy
    call = 63, // Call function (arg1 = func index, arg2 = num args)
    ret = 64, // Return from function
    halt = 65, // End execution

    // Variable operations
    store_var = 70, // Store top of stack to variable (arg1 = var index)
    load_array = 71, // Load array element (top=key, arg1=array idx)
    store_array = 72, // Store to array element
    incr_var = 73, // Increment variable
    decr_var = 74, // Decrement variable

    // I/O operations
    print = 80, // Print values (arg1 = num args)
    printf_op = 81, // Printf (arg1 = num args including format)
    emit_ofs = 82, // Emit output field separator
    emit_ors = 83, // Emit output record separator

    // Pattern/Regex operations
    match_regex = 90, // Match regex (arg1:arg2 = regex index)
    gsub_op = 91, // Global substitution
    sub_op = 92, // Single substitution
    match_fn = 93, // match() function

    // Loop control
    next_line = 95, // Skip to next line
    exit_prog = 96, // Exit program (top of stack = exit code)
    break_loop = 97,
    continue_loop = 98,

    // Dynamic field reference
    push_field_dyn = 100, // Push field by value on stack
};

/// Special variables
pub const SpecialVarType = enum(u8) {
    nr = 0, // Current line number
    nf = 1, // Number of fields
    fnr = 2, // Line number in current file
    fs = 3, // Field separator
    ofs = 4, // Output field separator
    ors = 5, // Output record separator
    filename = 6,
    argc = 7,
    subsep = 8,
};

/// Bytecode instruction (4 bytes, GPU-aligned)
pub const Instruction = extern struct {
    opcode: u8,
    arg1: u8,
    arg2: u8,
    arg3: u8,

    pub fn init(op: Opcode) Instruction {
        return .{ .opcode = @intFromEnum(op), .arg1 = 0, .arg2 = 0, .arg3 = 0 };
    }

    pub fn withArg1(op: Opcode, a1: u8) Instruction {
        return .{ .opcode = @intFromEnum(op), .arg1 = a1, .arg2 = 0, .arg3 = 0 };
    }

    pub fn withArgs(op: Opcode, a1: u8, a2: u8) Instruction {
        return .{ .opcode = @intFromEnum(op), .arg1 = a1, .arg2 = a2, .arg3 = 0 };
    }

    pub fn withOffset(op: Opcode, offset: u16) Instruction {
        return .{
            .opcode = @intFromEnum(op),
            .arg1 = @truncate(offset),
            .arg2 = @truncate(offset >> 8),
            .arg3 = 0,
        };
    }

    pub fn getOffset(self: Instruction) u16 {
        return @as(u16, self.arg1) | (@as(u16, self.arg2) << 8);
    }
};

/// GPU Value type (8 bytes, supports number or string reference)
pub const GpuValue = extern struct {
    number: f32, // Numeric value
    str_offset: u32, // Offset into string pool (0 = not a string)

    pub const EMPTY: GpuValue = .{ .number = 0, .str_offset = 0 };

    pub fn initNumber(n: f64) GpuValue {
        return .{ .number = @floatCast(n), .str_offset = 0 };
    }

    pub fn initString(offset: u32) GpuValue {
        return .{ .number = 0, .str_offset = offset };
    }

    pub fn isString(self: GpuValue) bool {
        return self.str_offset != 0;
    }

    pub fn asNumber(self: GpuValue) f32 {
        return self.number;
    }

    pub fn isTruthy(self: GpuValue) bool {
        if (self.str_offset != 0) return true; // Non-empty strings are truthy
        return self.number != 0;
    }
};

/// Compiled bytecode program
pub const BytecodeProgram = struct {
    instructions: []Instruction,
    num_constants: []f64, // Number constants pool
    str_constants: [][]const u8, // String constants pool
    num_variables: u32, // Number of local variables needed
    num_arrays: u32, // Number of arrays
    has_begin: bool,
    has_end: bool,
    begin_offset: u32, // Start of BEGIN block
    main_offset: u32, // Start of main rule processing
    end_offset: u32, // Start of END block
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BytecodeProgram) void {
        self.allocator.free(self.instructions);
        self.allocator.free(self.num_constants);
        for (self.str_constants) |s| {
            self.allocator.free(s);
        }
        self.allocator.free(self.str_constants);
    }
};

/// GPU execution configuration
pub const GpuExecConfig = extern struct {
    num_instructions: u32,
    num_constants: u32,
    num_variables: u32,
    stack_size: u32,
    max_output_per_thread: u32,
    main_offset: u32,
    flags: u32,
    _pad: u32 = 0,

    pub const FLAG_HAS_BEGIN: u32 = 1;
    pub const FLAG_HAS_END: u32 = 2;
};

// ============================================================================
// Bytecode Compiler - Converts AST to GPU bytecode
// ============================================================================

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    instructions: std.ArrayListUnmanaged(Instruction),
    num_constants: std.ArrayListUnmanaged(f64),
    str_constants: std.ArrayListUnmanaged([]const u8),
    variables: std.StringHashMapUnmanaged(u8), // Variable name -> index
    next_var_idx: u8,
    loop_depth: u32,
    loop_breaks: std.ArrayListUnmanaged(u32), // Instruction indices to patch
    loop_continues: std.ArrayListUnmanaged(u32),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .instructions = .{},
            .num_constants = .{},
            .str_constants = .{},
            .variables = .{},
            .next_var_idx = 0,
            .loop_depth = 0,
            .loop_breaks = .{},
            .loop_continues = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.instructions.deinit(self.allocator);
        self.num_constants.deinit(self.allocator);
        for (self.str_constants.items) |s| {
            self.allocator.free(s);
        }
        self.str_constants.deinit(self.allocator);
        self.variables.deinit(self.allocator);
        self.loop_breaks.deinit(self.allocator);
        self.loop_continues.deinit(self.allocator);
    }

    /// Compile an AWK program to bytecode
    pub fn compile(self: *Self, program: *ast.Program) !BytecodeProgram {
        var has_begin = false;
        var has_end = false;
        var begin_offset: u32 = 0;
        var main_offset: u32 = 0;
        var end_offset: u32 = 0;

        // Compile BEGIN block
        if (program.begin) |begin| {
            has_begin = true;
            begin_offset = @intCast(self.instructions.items.len);
            try self.compileStatement(begin);
            try self.emit(.halt);
        }

        // Compile main rules
        main_offset = @intCast(self.instructions.items.len);
        for (program.rules) |rule| {
            // Compile pattern (if present)
            if (rule.pattern) |pattern| {
                try self.compileExpression(pattern);
                const jmp_idx = self.instructions.items.len;
                try self.emitInst(Instruction.withOffset(.jmp_if_not, 0)); // Patch later
                try self.compileStatement(rule.action);
                // Patch jump
                const end_idx: u16 = @intCast(self.instructions.items.len);
                self.instructions.items[jmp_idx] = Instruction.withOffset(.jmp_if_not, end_idx);
            } else {
                // No pattern = matches all lines
                try self.compileStatement(rule.action);
            }
        }
        try self.emit(.halt);

        // Compile END block
        if (program.end) |end| {
            has_end = true;
            end_offset = @intCast(self.instructions.items.len);
            try self.compileStatement(end);
            try self.emit(.halt);
        }

        return BytecodeProgram{
            .instructions = try self.instructions.toOwnedSlice(self.allocator),
            .num_constants = try self.num_constants.toOwnedSlice(self.allocator),
            .str_constants = try self.str_constants.toOwnedSlice(self.allocator),
            .num_variables = self.next_var_idx,
            .num_arrays = 0, // TODO: array support
            .has_begin = has_begin,
            .has_end = has_end,
            .begin_offset = begin_offset,
            .main_offset = main_offset,
            .end_offset = end_offset,
            .allocator = self.allocator,
        };
    }

    fn emit(self: *Self, op: Opcode) !void {
        try self.instructions.append(self.allocator, Instruction.init(op));
    }

    fn emitInst(self: *Self, inst: Instruction) !void {
        try self.instructions.append(self.allocator, inst);
    }

    fn compileStatement(self: *Self, stmt: *ast.Statement) !void {
        switch (stmt.kind) {
            .block => |stmts| {
                for (stmts) |*s| {
                    var inner = s.*;
                    try self.compileStatement(&inner);
                }
            },
            .expression => |expr| {
                try self.compileExpression(expr);
                try self.emit(.pop); // Discard result
            },
            .print => |p| {
                for (p.args) |arg| {
                    try self.compileExpression(arg);
                }
                try self.emitInst(Instruction.withArg1(.print, @intCast(p.args.len)));
            },
            .printf => |pf| {
                try self.compileExpression(pf.format);
                for (pf.args) |arg| {
                    try self.compileExpression(arg);
                }
                try self.emitInst(Instruction.withArg1(.printf_op, @intCast(pf.args.len + 1)));
            },
            .if_stmt => |is| {
                try self.compileExpression(is.condition);
                const jmp_else_idx = self.instructions.items.len;
                try self.emitInst(Instruction.withOffset(.jmp_if_not, 0));
                try self.compileStatement(is.then_branch);
                if (is.else_branch) |eb| {
                    const jmp_end_idx = self.instructions.items.len;
                    try self.emitInst(Instruction.withOffset(.jmp, 0));
                    const else_start: u16 = @intCast(self.instructions.items.len);
                    self.instructions.items[jmp_else_idx] = Instruction.withOffset(.jmp_if_not, else_start);
                    try self.compileStatement(eb);
                    const end_idx: u16 = @intCast(self.instructions.items.len);
                    self.instructions.items[jmp_end_idx] = Instruction.withOffset(.jmp, end_idx);
                } else {
                    const end_idx: u16 = @intCast(self.instructions.items.len);
                    self.instructions.items[jmp_else_idx] = Instruction.withOffset(.jmp_if_not, end_idx);
                }
            },
            .while_stmt => |ws| {
                const loop_start: u32 = @intCast(self.instructions.items.len);
                self.loop_depth += 1;
                try self.compileExpression(ws.condition);
                const jmp_end_idx = self.instructions.items.len;
                try self.emitInst(Instruction.withOffset(.jmp_if_not, 0));
                try self.compileStatement(ws.body);
                try self.emitInst(Instruction.withOffset(.jmp, @intCast(loop_start)));
                const loop_end: u16 = @intCast(self.instructions.items.len);
                self.instructions.items[jmp_end_idx] = Instruction.withOffset(.jmp_if_not, loop_end);
                self.loop_depth -= 1;
                // Patch break/continue
                try self.patchLoopControls(loop_start, @intCast(loop_end));
            },
            .for_stmt => |fs| {
                if (fs.init) |init_stmt| {
                    try self.compileStatement(init_stmt);
                }
                const loop_start: u32 = @intCast(self.instructions.items.len);
                self.loop_depth += 1;
                if (fs.condition) |cond| {
                    try self.compileExpression(cond);
                    const jmp_idx = self.instructions.items.len;
                    try self.emitInst(Instruction.withOffset(.jmp_if_not, 0));
                    try self.compileStatement(fs.body);
                    if (fs.update) |upd| {
                        try self.compileExpression(upd);
                        try self.emit(.pop);
                    }
                    try self.emitInst(Instruction.withOffset(.jmp, @intCast(loop_start)));
                    const loop_end: u16 = @intCast(self.instructions.items.len);
                    self.instructions.items[jmp_idx] = Instruction.withOffset(.jmp_if_not, loop_end);
                    self.loop_depth -= 1;
                    try self.patchLoopControls(loop_start, @intCast(loop_end));
                } else {
                    try self.compileStatement(fs.body);
                    if (fs.update) |upd| {
                        try self.compileExpression(upd);
                        try self.emit(.pop);
                    }
                    try self.emitInst(Instruction.withOffset(.jmp, @intCast(loop_start)));
                    self.loop_depth -= 1;
                }
            },
            .break_stmt => {
                const idx: u32 = @intCast(self.instructions.items.len);
                try self.loop_breaks.append(self.allocator, idx);
                try self.emitInst(Instruction.withOffset(.jmp, 0)); // Patch later
            },
            .continue_stmt => {
                const idx: u32 = @intCast(self.instructions.items.len);
                try self.loop_continues.append(self.allocator, idx);
                try self.emitInst(Instruction.withOffset(.jmp, 0)); // Patch later
            },
            .next_stmt => try self.emit(.next_line),
            .exit_stmt => |exit_expr| {
                if (exit_expr) |expr| {
                    try self.compileExpression(expr);
                } else {
                    try self.emitInst(Instruction.withArgs(.push_num, 0, 0));
                }
                try self.emit(.exit_prog);
            },
            .return_stmt => |ret_expr| {
                if (ret_expr) |expr| {
                    try self.compileExpression(expr);
                } else {
                    try self.emitInst(Instruction.withArgs(.push_num, 0, 0));
                }
                try self.emit(.ret);
            },
            else => {
                // Other statement types - generate nop for now
                try self.emit(.nop);
            },
        }
    }

    fn compileExpression(self: *Self, expr: *ast.Expression) !void {
        switch (expr.kind) {
            .number_literal => |n| {
                const idx = try self.addNumConstant(n);
                try self.emitInst(Instruction.withArgs(.push_num, @truncate(idx), @truncate(idx >> 8)));
            },
            .string_literal => |s| {
                const idx = try self.addStrConstant(s);
                try self.emitInst(Instruction.withArgs(.push_str, @truncate(idx), @truncate(idx >> 8)));
            },
            .whole_line => {
                try self.emitInst(Instruction.withArg1(.push_field, 0));
            },
            .field_ref => |index_expr| {
                // Check if it's a literal field number
                if (index_expr.kind == .number_literal) {
                    const field_num: u8 = @intFromFloat(index_expr.kind.number_literal);
                    try self.emitInst(Instruction.withArg1(.push_field, field_num));
                } else {
                    // Dynamic field reference
                    try self.compileExpression(index_expr);
                    try self.emit(.push_field_dyn);
                }
            },
            .variable => |name| {
                // Check special variables
                if (std.mem.eql(u8, name, "NR")) {
                    try self.emitInst(Instruction.withArg1(.push_special, @intFromEnum(SpecialVarType.nr)));
                } else if (std.mem.eql(u8, name, "NF")) {
                    try self.emitInst(Instruction.withArg1(.push_special, @intFromEnum(SpecialVarType.nf)));
                } else if (std.mem.eql(u8, name, "FNR")) {
                    try self.emitInst(Instruction.withArg1(.push_special, @intFromEnum(SpecialVarType.fnr)));
                } else if (std.mem.eql(u8, name, "FS")) {
                    try self.emitInst(Instruction.withArg1(.push_special, @intFromEnum(SpecialVarType.fs)));
                } else if (std.mem.eql(u8, name, "OFS")) {
                    try self.emitInst(Instruction.withArg1(.push_special, @intFromEnum(SpecialVarType.ofs)));
                } else if (std.mem.eql(u8, name, "ORS")) {
                    try self.emitInst(Instruction.withArg1(.push_special, @intFromEnum(SpecialVarType.ors)));
                } else {
                    const var_idx = try self.getOrCreateVariable(name);
                    try self.emitInst(Instruction.withArg1(.push_var, var_idx));
                }
            },
            .binary_op => |bo| {
                try self.compileExpression(bo.left);
                try self.compileExpression(bo.right);
                const op: Opcode = switch (bo.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .mod => .mod,
                    .pow => .pow,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    .eq => .eq,
                    .ne => .ne,
                    .@"and" => .@"and",
                    .@"or" => .@"or",
                    .concat => .concat,
                    else => .nop,
                };
                try self.emit(op);
            },
            .unary_op => |uo| {
                try self.compileExpression(uo.operand);
                switch (uo.op) {
                    .negate => try self.emit(.neg),
                    .not => try self.emit(.not),
                    .pre_incr, .post_incr => {
                        if (uo.prefix) {
                            // ++x: increment then push
                            try self.emit(.dup);
                            try self.emitInst(Instruction.withArgs(.push_num, 0, 0)); // Push 1.0
                            try self.emit(.add);
                        }
                    },
                    .pre_decr, .post_decr => {
                        if (uo.prefix) {
                            try self.emit(.dup);
                            try self.emitInst(Instruction.withArgs(.push_num, 0, 0));
                            try self.emit(.sub);
                        }
                    },
                }
            },
            .assignment => |a| {
                try self.compileExpression(a.value);
                if (a.op) |op| {
                    // Compound assignment
                    try self.compileExpression(a.target);
                    const bin_op: Opcode = switch (op) {
                        .add_assign => .add,
                        .sub_assign => .sub,
                        .mul_assign => .mul,
                        .div_assign => .div,
                        .mod_assign => .mod,
                        .pow_assign => .pow,
                    };
                    try self.emit(bin_op);
                }
                // Store to target
                switch (a.target.kind) {
                    .variable => |name| {
                        const var_idx = try self.getOrCreateVariable(name);
                        try self.emit(.dup); // Keep value on stack
                        try self.emitInst(Instruction.withArg1(.store_var, var_idx));
                    },
                    else => {},
                }
            },
            .function_call => |fc| {
                // Compile arguments
                for (fc.args) |arg| {
                    try self.compileExpression(arg);
                }
                // Built-in functions
                if (std.mem.eql(u8, fc.name, "length")) {
                    try self.emit(.length);
                } else if (std.mem.eql(u8, fc.name, "substr")) {
                    try self.emit(.substr);
                } else if (std.mem.eql(u8, fc.name, "index")) {
                    try self.emit(.index_fn);
                } else if (std.mem.eql(u8, fc.name, "toupper")) {
                    try self.emit(.toupper);
                } else if (std.mem.eql(u8, fc.name, "tolower")) {
                    try self.emit(.tolower);
                } else if (std.mem.eql(u8, fc.name, "sin")) {
                    try self.emit(.sin);
                } else if (std.mem.eql(u8, fc.name, "cos")) {
                    try self.emit(.cos);
                } else if (std.mem.eql(u8, fc.name, "sqrt")) {
                    try self.emit(.sqrt);
                } else if (std.mem.eql(u8, fc.name, "int")) {
                    try self.emit(.int_fn);
                } else if (std.mem.eql(u8, fc.name, "log")) {
                    try self.emit(.log_fn);
                } else if (std.mem.eql(u8, fc.name, "exp")) {
                    try self.emit(.exp_fn);
                } else {
                    // User function - emit call
                    try self.emitInst(Instruction.withArgs(.call, 0, @intCast(fc.args.len)));
                }
            },
            .ternary => |t| {
                try self.compileExpression(t.condition);
                const jmp_false = self.instructions.items.len;
                try self.emitInst(Instruction.withOffset(.jmp_if_not, 0));
                try self.compileExpression(t.true_expr);
                const jmp_end = self.instructions.items.len;
                try self.emitInst(Instruction.withOffset(.jmp, 0));
                const false_start: u16 = @intCast(self.instructions.items.len);
                self.instructions.items[jmp_false] = Instruction.withOffset(.jmp_if_not, false_start);
                try self.compileExpression(t.false_expr);
                const end: u16 = @intCast(self.instructions.items.len);
                self.instructions.items[jmp_end] = Instruction.withOffset(.jmp, end);
            },
            else => {
                // Default: push 0
                try self.emitInst(Instruction.withArgs(.push_num, 0, 0));
            },
        }
    }

    fn addNumConstant(self: *Self, n: f64) !u16 {
        // Check if already exists
        for (self.num_constants.items, 0..) |c, i| {
            if (c == n) return @intCast(i);
        }
        const idx = self.num_constants.items.len;
        try self.num_constants.append(self.allocator, n);
        return @intCast(idx);
    }

    fn addStrConstant(self: *Self, s: []const u8) !u16 {
        // Check if already exists
        for (self.str_constants.items, 0..) |c, i| {
            if (std.mem.eql(u8, c, s)) return @intCast(i);
        }
        const idx = self.str_constants.items.len;
        const copy = try self.allocator.dupe(u8, s);
        try self.str_constants.append(self.allocator, copy);
        return @intCast(idx);
    }

    fn getOrCreateVariable(self: *Self, name: []const u8) !u8 {
        if (self.variables.get(name)) |idx| {
            return idx;
        }
        const idx = self.next_var_idx;
        self.next_var_idx += 1;
        try self.variables.put(self.allocator, name, idx);
        return idx;
    }

    fn patchLoopControls(self: *Self, loop_start: u32, loop_end: u32) !void {
        // Patch break statements to jump to end
        for (self.loop_breaks.items) |idx| {
            self.instructions.items[idx] = Instruction.withOffset(.jmp, @intCast(loop_end));
        }
        self.loop_breaks.clearRetainingCapacity();

        // Patch continue statements to jump to start
        for (self.loop_continues.items) |idx| {
            self.instructions.items[idx] = Instruction.withOffset(.jmp, @intCast(loop_start));
        }
        self.loop_continues.clearRetainingCapacity();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "bytecode: simple print" {
    const allocator = std.testing.allocator;
    var compiler = Compiler.init(allocator);
    defer compiler.deinit();

    // Simple test - just compile a push and print
    try compiler.emit(Instruction.withArg1(.push_field, 1));
    try compiler.emit(Instruction.withArg1(.print, 1));
    try compiler.emit(.halt);

    try std.testing.expectEqual(@as(usize, 3), compiler.instructions.items.len);
}
