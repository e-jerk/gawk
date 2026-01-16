const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;

// ============================================================================
// AWK Abstract Syntax Tree
// Represents the parsed structure of an AWK program
// ============================================================================

/// Complete AWK program
pub const Program = struct {
    /// BEGIN block statements (executed before input processing)
    begin: ?*Statement = null,

    /// Pattern-action rules (executed for each input line)
    rules: []Rule = &.{},

    /// END block statements (executed after all input)
    end: ?*Statement = null,

    /// User-defined functions
    functions: std.StringHashMapUnmanaged(Function) = .{},

    allocator: Allocator,

    pub fn deinit(self: *Program) void {
        if (self.begin) |b| b.deinit(self.allocator);
        for (self.rules) |rule| {
            if (rule.pattern) |p| p.deinit(self.allocator);
            rule.action.deinit(self.allocator);
        }
        if (self.rules.len > 0) self.allocator.free(self.rules);
        if (self.end) |e| e.deinit(self.allocator);

        var it = self.functions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.functions.deinit(self.allocator);
    }
};

/// A single pattern-action rule
pub const Rule = struct {
    /// Pattern to match (null = match all lines)
    pattern: ?*Expression = null,

    /// Pattern range end (for /start/,/end/ patterns)
    pattern_end: ?*Expression = null,

    /// Action to execute when pattern matches
    action: *Statement,
};

/// User-defined function
pub const Function = struct {
    name: []const u8,
    params: [][]const u8,
    body: *Statement,

    pub fn deinit(self: *Function, allocator: Allocator) void {
        allocator.free(self.params);
        self.body.deinit(allocator);
    }
};

// ============================================================================
// Expressions
// ============================================================================

pub const Expression = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        /// Numeric literal: 42, 3.14
        number_literal: f64,

        /// String literal: "hello"
        string_literal: []const u8,

        /// Regex literal: /pattern/
        regex_literal: []const u8,

        /// Field reference: $1, $NF, $(expr)
        field_ref: *Expression,

        /// Variable reference: x, NR, NF
        variable: []const u8,

        /// Array subscript: arr[key]
        array_subscript: struct {
            array: []const u8,
            index: *Expression,
        },

        /// Binary operation: a + b, a < b, etc.
        binary_op: struct {
            op: BinaryOp,
            left: *Expression,
            right: *Expression,
        },

        /// Unary operation: -x, !x, ++x, x++
        unary_op: struct {
            op: UnaryOp,
            operand: *Expression,
            prefix: bool, // true for ++x, false for x++
        },

        /// Assignment: x = 5, arr[k] = v
        assignment: struct {
            target: *Expression,
            value: *Expression,
            op: ?AssignOp, // null for simple =, or +=, -=, etc.
        },

        /// Ternary conditional: cond ? true_expr : false_expr
        ternary: struct {
            condition: *Expression,
            true_expr: *Expression,
            false_expr: *Expression,
        },

        /// Function call: length($1), substr(s, 1, 3)
        function_call: struct {
            name: []const u8,
            args: []*Expression,
        },

        /// Regex match: str ~ /pattern/ or str !~ /pattern/
        regex_match: struct {
            string: *Expression,
            pattern: *Expression,
            negated: bool,
        },

        /// In expression: (key in array)
        in_expr: struct {
            key: *Expression,
            array: []const u8,
        },

        /// Getline expression: getline var < file
        getline: struct {
            var_name: ?[]const u8,
            file: ?*Expression,
            pipe_cmd: ?*Expression,
        },

        /// Concatenation (implicit string concat in AWK)
        concat: struct {
            left: *Expression,
            right: *Expression,
        },

        /// Special: $0 (whole line)
        whole_line: void,
    };

    pub fn deinit(self: *Expression, allocator: Allocator) void {
        switch (self.kind) {
            .field_ref => |fr| {
                fr.deinit(allocator);
                allocator.destroy(fr);
            },
            .array_subscript => |as| {
                as.index.deinit(allocator);
                allocator.destroy(as.index);
            },
            .binary_op => |bo| {
                bo.left.deinit(allocator);
                allocator.destroy(bo.left);
                bo.right.deinit(allocator);
                allocator.destroy(bo.right);
            },
            .unary_op => |uo| {
                uo.operand.deinit(allocator);
                allocator.destroy(uo.operand);
            },
            .assignment => |a| {
                a.target.deinit(allocator);
                allocator.destroy(a.target);
                a.value.deinit(allocator);
                allocator.destroy(a.value);
            },
            .ternary => |t| {
                t.condition.deinit(allocator);
                allocator.destroy(t.condition);
                t.true_expr.deinit(allocator);
                allocator.destroy(t.true_expr);
                t.false_expr.deinit(allocator);
                allocator.destroy(t.false_expr);
            },
            .function_call => |fc| {
                for (fc.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(fc.args);
            },
            .regex_match => |rm| {
                rm.string.deinit(allocator);
                allocator.destroy(rm.string);
                rm.pattern.deinit(allocator);
                allocator.destroy(rm.pattern);
            },
            .in_expr => |ie| {
                ie.key.deinit(allocator);
                allocator.destroy(ie.key);
            },
            .getline => |gl| {
                if (gl.file) |f| {
                    f.deinit(allocator);
                    allocator.destroy(f);
                }
                if (gl.pipe_cmd) |p| {
                    p.deinit(allocator);
                    allocator.destroy(p);
                }
            },
            .concat => |c| {
                c.left.deinit(allocator);
                allocator.destroy(c.left);
                c.right.deinit(allocator);
                allocator.destroy(c.right);
            },
            .number_literal, .string_literal, .regex_literal, .variable, .whole_line => {},
        }
    }

    /// Create a number literal expression
    pub fn numberLiteral(allocator: Allocator, n: f64) !*Expression {
        const expr = try allocator.create(Expression);
        expr.* = .{ .kind = .{ .number_literal = n } };
        return expr;
    }

    /// Create a string literal expression
    pub fn stringLiteral(allocator: Allocator, s: []const u8) !*Expression {
        const expr = try allocator.create(Expression);
        expr.* = .{ .kind = .{ .string_literal = s } };
        return expr;
    }

    /// Create a variable reference expression
    pub fn variableRef(allocator: Allocator, name: []const u8) !*Expression {
        const expr = try allocator.create(Expression);
        expr.* = .{ .kind = .{ .variable = name } };
        return expr;
    }

    /// Create a field reference expression
    pub fn fieldRef(allocator: Allocator, index: *Expression) !*Expression {
        const expr = try allocator.create(Expression);
        expr.* = .{ .kind = .{ .field_ref = index } };
        return expr;
    }

    /// Create a binary operation expression
    pub fn binaryOp(allocator: Allocator, op: BinaryOp, left: *Expression, right: *Expression) !*Expression {
        const expr = try allocator.create(Expression);
        expr.* = .{ .kind = .{ .binary_op = .{ .op = op, .left = left, .right = right } } };
        return expr;
    }
};

pub const BinaryOp = enum {
    // Arithmetic
    add, // +
    sub, // -
    mul, // *
    div, // /
    mod, // %
    pow, // ^

    // Comparison
    lt, // <
    le, // <=
    gt, // >
    ge, // >=
    eq, // ==
    ne, // !=

    // Logical
    @"and", // &&
    @"or", // ||

    // String
    concat, // (implicit)
    match, // ~
    not_match, // !~
};

pub const UnaryOp = enum {
    negate, // -x
    not, // !x
    pre_incr, // ++x
    pre_decr, // --x
    post_incr, // x++
    post_decr, // x--
};

pub const AssignOp = enum {
    add_assign, // +=
    sub_assign, // -=
    mul_assign, // *=
    div_assign, // /=
    mod_assign, // %=
    pow_assign, // ^=
};

// ============================================================================
// Statements
// ============================================================================

pub const Statement = struct {
    kind: Kind,

    pub const Kind = union(enum) {
        /// Block of statements: { stmt1; stmt2; }
        block: []Statement,

        /// Expression statement (side effects): x = 5
        expression: *Expression,

        /// Print statement: print expr1, expr2
        print: struct {
            args: []*Expression,
            output_file: ?*Expression,
            append: bool, // >> vs >
        },

        /// Printf statement: printf "format", args...
        printf: struct {
            format: *Expression,
            args: []*Expression,
            output_file: ?*Expression,
            append: bool,
        },

        /// If statement: if (cond) stmt [else stmt]
        if_stmt: struct {
            condition: *Expression,
            then_branch: *Statement,
            else_branch: ?*Statement,
        },

        /// While loop: while (cond) stmt
        while_stmt: struct {
            condition: *Expression,
            body: *Statement,
        },

        /// Do-while loop: do stmt while (cond)
        do_while_stmt: struct {
            body: *Statement,
            condition: *Expression,
        },

        /// For loop: for (init; cond; update) stmt
        for_stmt: struct {
            init: ?*Statement,
            condition: ?*Expression,
            update: ?*Expression,
            body: *Statement,
        },

        /// For-in loop: for (var in array) stmt
        for_in_stmt: struct {
            var_name: []const u8,
            array_name: []const u8,
            body: *Statement,
        },

        /// Break statement
        break_stmt: void,

        /// Continue statement
        continue_stmt: void,

        /// Next statement (skip to next input line)
        next_stmt: void,

        /// Exit statement: exit [expr]
        exit_stmt: ?*Expression,

        /// Return statement: return [expr]
        return_stmt: ?*Expression,

        /// Delete statement: delete array[key]
        delete_stmt: struct {
            array: []const u8,
            index: ?*Expression, // null = delete entire array
        },

        /// Getline statement (different from expression form)
        getline_stmt: struct {
            var_name: ?[]const u8,
            file: ?*Expression,
        },

        /// Empty statement (just a semicolon)
        empty: void,
    };

    pub fn deinit(self: *Statement, allocator: Allocator) void {
        switch (self.kind) {
            .block => |stmts| {
                for (stmts) |*stmt| {
                    var s = stmt.*;
                    s.deinit(allocator);
                }
                allocator.free(stmts);
            },
            .expression => |expr| {
                expr.deinit(allocator);
                allocator.destroy(expr);
            },
            .print => |p| {
                for (p.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(p.args);
                if (p.output_file) |of| {
                    of.deinit(allocator);
                    allocator.destroy(of);
                }
            },
            .printf => |pf| {
                pf.format.deinit(allocator);
                allocator.destroy(pf.format);
                for (pf.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(pf.args);
                if (pf.output_file) |of| {
                    of.deinit(allocator);
                    allocator.destroy(of);
                }
            },
            .if_stmt => |is| {
                is.condition.deinit(allocator);
                allocator.destroy(is.condition);
                is.then_branch.deinit(allocator);
                allocator.destroy(is.then_branch);
                if (is.else_branch) |eb| {
                    eb.deinit(allocator);
                    allocator.destroy(eb);
                }
            },
            .while_stmt => |ws| {
                ws.condition.deinit(allocator);
                allocator.destroy(ws.condition);
                ws.body.deinit(allocator);
                allocator.destroy(ws.body);
            },
            .do_while_stmt => |dw| {
                dw.body.deinit(allocator);
                allocator.destroy(dw.body);
                dw.condition.deinit(allocator);
                allocator.destroy(dw.condition);
            },
            .for_stmt => |fs| {
                if (fs.init) |i| {
                    i.deinit(allocator);
                    allocator.destroy(i);
                }
                if (fs.condition) |c| {
                    c.deinit(allocator);
                    allocator.destroy(c);
                }
                if (fs.update) |u| {
                    u.deinit(allocator);
                    allocator.destroy(u);
                }
                fs.body.deinit(allocator);
                allocator.destroy(fs.body);
            },
            .for_in_stmt => |fis| {
                fis.body.deinit(allocator);
                allocator.destroy(fis.body);
            },
            .exit_stmt => |es| {
                if (es) |e| {
                    e.deinit(allocator);
                    allocator.destroy(e);
                }
            },
            .return_stmt => |rs| {
                if (rs) |r| {
                    r.deinit(allocator);
                    allocator.destroy(r);
                }
            },
            .delete_stmt => |ds| {
                if (ds.index) |i| {
                    i.deinit(allocator);
                    allocator.destroy(i);
                }
            },
            .getline_stmt => |gl| {
                if (gl.file) |f| {
                    f.deinit(allocator);
                    allocator.destroy(f);
                }
            },
            .break_stmt, .continue_stmt, .next_stmt, .empty => {},
        }
    }

    /// Create a block statement
    pub fn block(allocator: Allocator, stmts: []Statement) !*Statement {
        const stmt = try allocator.create(Statement);
        stmt.* = .{ .kind = .{ .block = stmts } };
        return stmt;
    }

    /// Create an expression statement
    pub fn expression(allocator: Allocator, expr: *Expression) !*Statement {
        const stmt = try allocator.create(Statement);
        stmt.* = .{ .kind = .{ .expression = expr } };
        return stmt;
    }

    /// Create a print statement
    pub fn print(allocator: Allocator, args: []*Expression) !*Statement {
        const stmt = try allocator.create(Statement);
        stmt.* = .{ .kind = .{ .print = .{ .args = args, .output_file = null, .append = false } } };
        return stmt;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "AST: create number literal" {
    const allocator = std.testing.allocator;
    const expr = try Expression.numberLiteral(allocator, 42.0);
    defer allocator.destroy(expr);

    switch (expr.kind) {
        .number_literal => |n| try std.testing.expectEqual(@as(f64, 42.0), n),
        else => return error.UnexpectedExpressionKind,
    }
}

test "AST: create binary operation" {
    const allocator = std.testing.allocator;
    const left = try Expression.numberLiteral(allocator, 1.0);
    const right = try Expression.numberLiteral(allocator, 2.0);
    const expr = try Expression.binaryOp(allocator, .add, left, right);
    defer {
        expr.deinit(allocator);
        allocator.destroy(expr);
    }

    switch (expr.kind) {
        .binary_op => |bo| {
            try std.testing.expectEqual(BinaryOp.add, bo.op);
        },
        else => return error.UnexpectedExpressionKind,
    }
}
