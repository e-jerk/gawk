const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;

// ============================================================================
// AWK Tokenizer and Parser
// Implements a recursive descent parser for AWK programs
// ============================================================================

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidRegex,
    InvalidString,
    UnterminatedString,
    UnterminatedRegex,
    UnexpectedCharacter,
    TooManyArguments,
    OutOfMemory,
};

// ============================================================================
// Token Types
// ============================================================================

pub const Token = struct {
    kind: Kind,
    lexeme: []const u8,
    line: u32,
    column: u32,

    pub const Kind = enum {
        // Literals
        number,
        string,
        regex,
        identifier,

        // Keywords
        kw_begin,
        kw_end,
        kw_if,
        kw_else,
        kw_while,
        kw_do,
        kw_for,
        kw_in,
        kw_break,
        kw_continue,
        kw_next,
        kw_exit,
        kw_return,
        kw_delete,
        kw_function,
        kw_print,
        kw_printf,
        kw_getline,

        // Operators
        plus, // +
        minus, // -
        star, // *
        slash, // /
        percent, // %
        caret, // ^
        dollar, // $

        lt, // <
        le, // <=
        gt, // >
        ge, // >=
        eq, // ==
        ne, // !=
        match, // ~
        not_match, // !~

        ampamp, // &&
        pipepipe, // ||
        bang, // !

        assign, // =
        plus_assign, // +=
        minus_assign, // -=
        star_assign, // *=
        slash_assign, // /=
        percent_assign, // %=
        caret_assign, // ^=

        plusplus, // ++
        minusminus, // --

        question, // ?
        colon, // :

        // Delimiters
        lparen, // (
        rparen, // )
        lbrace, // {
        rbrace, // }
        lbracket, // [
        rbracket, // ]
        comma, // ,
        semicolon, // ;
        newline,

        // Special
        pipe, // |
        append, // >>
        eof,
        invalid,
    };
};

// ============================================================================
// Tokenizer
// ============================================================================

pub const Tokenizer = struct {
    source: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    column: u32 = 1,

    /// Tracks whether we're in a context where / starts a regex
    expect_regex: bool = true,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source };
    }

    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, "");
        }

        const start_pos = self.pos;
        const start_line = self.line;
        const start_col = self.column;
        const c = self.advance();

        const kind: Token.Kind = switch (c) {
            '\n' => blk: {
                self.expect_regex = true;
                break :blk .newline;
            },
            '+' => if (self.match('+')) .plusplus else if (self.match('=')) .plus_assign else .plus,
            '-' => if (self.match('-')) .minusminus else if (self.match('=')) .minus_assign else .minus,
            '*' => if (self.match('=')) .star_assign else .star,
            '/' => if (self.expect_regex) self.scanRegex() else if (self.match('=')) .slash_assign else .slash,
            '%' => if (self.match('=')) .percent_assign else .percent,
            '^' => if (self.match('=')) .caret_assign else .caret,
            '$' => .dollar,
            '<' => if (self.match('=')) .le else .lt,
            '>' => if (self.match('>')) .append else if (self.match('=')) .ge else .gt,
            '=' => if (self.match('=')) .eq else .assign,
            '!' => if (self.match('~')) .not_match else if (self.match('=')) .ne else .bang,
            '~' => .match,
            '&' => if (self.match('&')) .ampamp else .invalid,
            '|' => if (self.match('|')) .pipepipe else .pipe,
            '?' => .question,
            ':' => .colon,
            '(' => blk: {
                self.expect_regex = true;
                break :blk .lparen;
            },
            ')' => blk: {
                self.expect_regex = false;
                break :blk .rparen;
            },
            '{' => blk: {
                self.expect_regex = true;
                break :blk .lbrace;
            },
            '}' => blk: {
                self.expect_regex = true;
                break :blk .rbrace;
            },
            '[' => .lbracket,
            ']' => blk: {
                self.expect_regex = false;
                break :blk .rbracket;
            },
            ',' => blk: {
                self.expect_regex = true;
                break :blk .comma;
            },
            ';' => blk: {
                self.expect_regex = true;
                break :blk .semicolon;
            },
            '"' => self.scanString(),
            else => blk: {
                if (isDigit(c)) {
                    break :blk self.scanNumber();
                } else if (isAlpha(c) or c == '_') {
                    break :blk self.scanIdentifierOrKeyword();
                } else {
                    break :blk .invalid;
                }
            },
        };

        // Update expect_regex based on token type
        switch (kind) {
            .number, .string, .identifier, .rparen, .rbracket => self.expect_regex = false,
            .comma, .semicolon, .lparen, .lbrace, .assign, .plus_assign, .minus_assign, .star_assign, .slash_assign, .percent_assign, .caret_assign, .match, .not_match, .lt, .le, .gt, .ge, .eq, .ne, .ampamp, .pipepipe, .bang, .question, .colon => self.expect_regex = true,
            else => {},
        }

        return Token{
            .kind = kind,
            .lexeme = self.source[start_pos..self.pos],
            .line = start_line,
            .column = start_col,
        };
    }

    fn makeToken(self: *const Tokenizer, kind: Token.Kind, lexeme: []const u8) Token {
        return .{
            .kind = kind,
            .lexeme = lexeme,
            .line = self.line,
            .column = self.column,
        };
    }

    fn advance(self: *Tokenizer) u8 {
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn peek(self: *const Tokenizer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn match(self: *Tokenizer, expected: u8) bool {
        if (self.pos >= self.source.len) return false;
        if (self.source[self.pos] != expected) return false;
        _ = self.advance();
        return true;
    }

    fn skipWhitespaceAndComments(self: *Tokenizer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            switch (c) {
                ' ', '\t', '\r' => _ = self.advance(),
                '#' => {
                    // Skip comment to end of line
                    while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                        _ = self.advance();
                    }
                },
                '\\' => {
                    // Line continuation
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '\n') {
                        _ = self.advance();
                        _ = self.advance();
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn scanNumber(self: *Tokenizer) Token.Kind {
        // Integer part
        while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
            _ = self.advance();
        }

        // Decimal part
        if (self.pos < self.source.len and self.source[self.pos] == '.' and
            self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))
        {
            _ = self.advance(); // consume '.'
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                _ = self.advance();
            }
        }

        // Exponent part
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            _ = self.advance();
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                _ = self.advance();
            }
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                _ = self.advance();
            }
        }

        return .number;
    }

    fn scanString(self: *Tokenizer) Token.Kind {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                _ = self.advance();
                return .string;
            }
            if (c == '\\' and self.pos + 1 < self.source.len) {
                _ = self.advance(); // skip backslash
            }
            if (c == '\n') {
                return .invalid; // Unterminated string
            }
            _ = self.advance();
        }
        return .invalid; // Unterminated string
    }

    fn scanRegex(self: *Tokenizer) Token.Kind {
        // Already consumed the opening /
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '/') {
                _ = self.advance();
                return .regex;
            }
            if (c == '\\' and self.pos + 1 < self.source.len) {
                _ = self.advance(); // skip backslash
            }
            if (c == '\n') {
                return .invalid; // Unterminated regex
            }
            _ = self.advance();
        }
        return .invalid;
    }

    fn scanIdentifierOrKeyword(self: *Tokenizer) Token.Kind {
        const start = self.pos - 1; // We already consumed first char

        while (self.pos < self.source.len and (isAlphaNumeric(self.source[self.pos]) or self.source[self.pos] == '_')) {
            _ = self.advance();
        }

        const ident = self.source[start..self.pos];

        // Check for keywords
        const keywords = std.StaticStringMap(Token.Kind).initComptime(.{
            .{ "BEGIN", .kw_begin },
            .{ "END", .kw_end },
            .{ "if", .kw_if },
            .{ "else", .kw_else },
            .{ "while", .kw_while },
            .{ "do", .kw_do },
            .{ "for", .kw_for },
            .{ "in", .kw_in },
            .{ "break", .kw_break },
            .{ "continue", .kw_continue },
            .{ "next", .kw_next },
            .{ "exit", .kw_exit },
            .{ "return", .kw_return },
            .{ "delete", .kw_delete },
            .{ "function", .kw_function },
            .{ "print", .kw_print },
            .{ "printf", .kw_printf },
            .{ "getline", .kw_getline },
        });

        return keywords.get(ident) orelse .identifier;
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
    }

    fn isAlphaNumeric(c: u8) bool {
        return isAlpha(c) or isDigit(c);
    }
};

// ============================================================================
// Parser
// ============================================================================

pub const Parser = struct {
    tokenizer: Tokenizer,
    current: Token,
    previous: Token,
    allocator: Allocator,
    had_error: bool = false,

    pub fn init(source: []const u8, allocator: Allocator) Parser {
        var parser = Parser{
            .tokenizer = Tokenizer.init(source),
            .current = undefined,
            .previous = undefined,
            .allocator = allocator,
        };
        parser.advance(); // Prime the parser
        return parser;
    }

    /// Parse a complete AWK program
    pub fn parse(self: *Parser) ParseError!ast.Program {
        var program = ast.Program{
            .allocator = self.allocator,
        };
        errdefer program.deinit();

        var rules = std.ArrayListUnmanaged(ast.Rule){};
        defer rules.deinit(self.allocator);

        while (!self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.eof)) break;

            if (self.check(.kw_begin)) {
                self.advance();
                program.begin = try self.parseAction();
            } else if (self.check(.kw_end)) {
                self.advance();
                program.end = try self.parseAction();
            } else if (self.check(.kw_function)) {
                const func = try self.parseFunction();
                try program.functions.put(self.allocator, func.name, func);
            } else {
                // Pattern-action rule
                const rule = try self.parseRule();
                try rules.append(self.allocator, rule);
            }

            self.skipNewlines();
        }

        program.rules = try rules.toOwnedSlice(self.allocator);
        return program;
    }

    fn parseRule(self: *Parser) ParseError!ast.Rule {
        var rule = ast.Rule{
            .action = undefined,
        };

        // Check for pattern
        if (!self.check(.lbrace)) {
            rule.pattern = try self.parseExpression();

            // Check for pattern range
            if (self.check(.comma)) {
                self.advance();
                rule.pattern_end = try self.parseExpression();
            }
        }

        // Parse action (or use default print)
        if (self.check(.lbrace)) {
            rule.action = try self.parseAction();
        } else {
            // Default action: { print }
            const print_args = try self.allocator.alloc(*ast.Expression, 0);
            rule.action = try ast.Statement.print(self.allocator, print_args);
        }

        return rule;
    }

    fn parseAction(self: *Parser) ParseError!*ast.Statement {
        try self.consume(.lbrace, "Expected '{' before action");
        self.skipNewlines();

        var stmts = std.ArrayListUnmanaged(ast.Statement){};
        defer stmts.deinit(self.allocator);

        while (!self.check(.rbrace) and !self.check(.eof)) {
            const stmt = try self.parseStatement();
            try stmts.append(self.allocator, stmt.*);
            self.allocator.destroy(stmt);
            self.skipNewlines();
        }

        try self.consume(.rbrace, "Expected '}' after action");

        const block_stmts = try stmts.toOwnedSlice(self.allocator);
        return ast.Statement.block(self.allocator, block_stmts);
    }

    fn parseFunction(self: *Parser) ParseError!ast.Function {
        try self.consume(.kw_function, "Expected 'function'");
        try self.consume(.identifier, "Expected function name");
        const name = self.previous.lexeme;

        try self.consume(.lparen, "Expected '(' after function name");

        var params = std.ArrayListUnmanaged([]const u8){};
        defer params.deinit(self.allocator);

        if (!self.check(.rparen)) {
            while (true) {
                try self.consume(.identifier, "Expected parameter name");
                try params.append(self.allocator, self.previous.lexeme);
                if (!self.match(.comma)) break;
            }
        }

        try self.consume(.rparen, "Expected ')' after parameters");

        const body = try self.parseAction();

        return ast.Function{
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .body = body,
        };
    }

    fn parseStatement(self: *Parser) ParseError!*ast.Statement {
        if (self.check(.kw_if)) return self.parseIf();
        if (self.check(.kw_while)) return self.parseWhile();
        if (self.check(.kw_do)) return self.parseDoWhile();
        if (self.check(.kw_for)) return self.parseFor();
        if (self.check(.kw_break)) {
            self.advance();
            self.consumeStatementEnd();
            const stmt = try self.allocator.create(ast.Statement);
            stmt.* = .{ .kind = .break_stmt };
            return stmt;
        }
        if (self.check(.kw_continue)) {
            self.advance();
            self.consumeStatementEnd();
            const stmt = try self.allocator.create(ast.Statement);
            stmt.* = .{ .kind = .continue_stmt };
            return stmt;
        }
        if (self.check(.kw_next)) {
            self.advance();
            self.consumeStatementEnd();
            const stmt = try self.allocator.create(ast.Statement);
            stmt.* = .{ .kind = .next_stmt };
            return stmt;
        }
        if (self.check(.kw_exit)) return self.parseExit();
        if (self.check(.kw_return)) return self.parseReturn();
        if (self.check(.kw_delete)) return self.parseDelete();
        if (self.check(.kw_print)) return self.parsePrint();
        if (self.check(.kw_printf)) return self.parsePrintf();
        if (self.check(.lbrace)) return self.parseAction();

        // Expression statement
        const expr = try self.parseExpression();
        self.consumeStatementEnd();
        return ast.Statement.expression(self.allocator, expr);
    }

    fn parseIf(self: *Parser) ParseError!*ast.Statement {
        self.advance(); // consume 'if'
        try self.consume(.lparen, "Expected '(' after 'if'");
        const condition = try self.parseExpression();
        try self.consume(.rparen, "Expected ')' after condition");
        self.skipNewlines();
        const then_branch = try self.parseStatement();

        var else_branch: ?*ast.Statement = null;
        self.skipNewlines();
        if (self.match(.kw_else)) {
            self.skipNewlines();
            else_branch = try self.parseStatement();
        }

        const stmt = try self.allocator.create(ast.Statement);
        stmt.* = .{ .kind = .{ .if_stmt = .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
        } } };
        return stmt;
    }

    fn parseWhile(self: *Parser) ParseError!*ast.Statement {
        self.advance(); // consume 'while'
        try self.consume(.lparen, "Expected '(' after 'while'");
        const condition = try self.parseExpression();
        try self.consume(.rparen, "Expected ')' after condition");
        self.skipNewlines();
        const body = try self.parseStatement();

        const stmt = try self.allocator.create(ast.Statement);
        stmt.* = .{ .kind = .{ .while_stmt = .{
            .condition = condition,
            .body = body,
        } } };
        return stmt;
    }

    fn parseDoWhile(self: *Parser) ParseError!*ast.Statement {
        self.advance(); // consume 'do'
        self.skipNewlines();
        const body = try self.parseStatement();
        self.skipNewlines();
        try self.consume(.kw_while, "Expected 'while' after do body");
        try self.consume(.lparen, "Expected '(' after 'while'");
        const condition = try self.parseExpression();
        try self.consume(.rparen, "Expected ')' after condition");
        self.consumeStatementEnd();

        const stmt = try self.allocator.create(ast.Statement);
        stmt.* = .{ .kind = .{ .do_while_stmt = .{
            .body = body,
            .condition = condition,
        } } };
        return stmt;
    }

    fn parseFor(self: *Parser) ParseError!*ast.Statement {
        self.advance(); // consume 'for'
        try self.consume(.lparen, "Expected '(' after 'for'");

        // Check for for-in loop
        if (self.check(.identifier)) {
            const saved_pos = self.tokenizer.pos;
            const var_name = self.current.lexeme;
            self.advance();

            if (self.check(.kw_in)) {
                self.advance();
                try self.consume(.identifier, "Expected array name after 'in'");
                const array_name = self.previous.lexeme;
                try self.consume(.rparen, "Expected ')' after for-in");
                self.skipNewlines();
                const body = try self.parseStatement();

                const stmt = try self.allocator.create(ast.Statement);
                stmt.* = .{ .kind = .{ .for_in_stmt = .{
                    .var_name = var_name,
                    .array_name = array_name,
                    .body = body,
                } } };
                return stmt;
            }

            // Not a for-in, reset
            self.tokenizer.pos = saved_pos;
            self.advance();
        }

        // Regular for loop: for (init; cond; update)
        var init_stmt: ?*ast.Statement = null;
        if (!self.check(.semicolon)) {
            const init_expr = try self.parseExpression();
            init_stmt = try ast.Statement.expression(self.allocator, init_expr);
        }
        try self.consume(.semicolon, "Expected ';' after for initializer");

        var condition: ?*ast.Expression = null;
        if (!self.check(.semicolon)) {
            condition = try self.parseExpression();
        }
        try self.consume(.semicolon, "Expected ';' after for condition");

        var update: ?*ast.Expression = null;
        if (!self.check(.rparen)) {
            update = try self.parseExpression();
        }
        try self.consume(.rparen, "Expected ')' after for clauses");

        self.skipNewlines();
        const body = try self.parseStatement();

        const stmt = try self.allocator.create(ast.Statement);
        stmt.* = .{ .kind = .{ .for_stmt = .{
            .init = init_stmt,
            .condition = condition,
            .update = update,
            .body = body,
        } } };
        return stmt;
    }

    fn parseExit(self: *Parser) ParseError!*ast.Statement {
        self.advance(); // consume 'exit'
        var expr: ?*ast.Expression = null;
        if (!self.checkStatementEnd()) {
            expr = try self.parseExpression();
        }
        self.consumeStatementEnd();

        const stmt = try self.allocator.create(ast.Statement);
        stmt.* = .{ .kind = .{ .exit_stmt = expr } };
        return stmt;
    }

    fn parseReturn(self: *Parser) ParseError!*ast.Statement {
        self.advance(); // consume 'return'
        var expr: ?*ast.Expression = null;
        if (!self.checkStatementEnd()) {
            expr = try self.parseExpression();
        }
        self.consumeStatementEnd();

        const stmt = try self.allocator.create(ast.Statement);
        stmt.* = .{ .kind = .{ .return_stmt = expr } };
        return stmt;
    }

    fn parseDelete(self: *Parser) ParseError!*ast.Statement {
        self.advance(); // consume 'delete'
        try self.consume(.identifier, "Expected array name after 'delete'");
        const array_name = self.previous.lexeme;

        var index: ?*ast.Expression = null;
        if (self.match(.lbracket)) {
            index = try self.parseExpression();
            try self.consume(.rbracket, "Expected ']' after index");
        }
        self.consumeStatementEnd();

        const stmt = try self.allocator.create(ast.Statement);
        stmt.* = .{ .kind = .{ .delete_stmt = .{
            .array = array_name,
            .index = index,
        } } };
        return stmt;
    }

    fn parsePrint(self: *Parser) ParseError!*ast.Statement {
        self.advance(); // consume 'print'

        var args = std.ArrayListUnmanaged(*ast.Expression){};
        defer args.deinit(self.allocator);

        // Parse print arguments
        if (!self.checkStatementEnd() and !self.check(.gt) and !self.check(.append) and !self.check(.pipe)) {
            while (true) {
                const arg = try self.parseExpression();
                try args.append(self.allocator, arg);
                if (!self.match(.comma)) break;
            }
        }

        var output_file: ?*ast.Expression = null;
        var append = false;

        // Check for output redirection
        if (self.match(.gt)) {
            output_file = try self.parseExpression();
        } else if (self.match(.append)) {
            output_file = try self.parseExpression();
            append = true;
        }

        self.consumeStatementEnd();

        const stmt = try self.allocator.create(ast.Statement);
        stmt.* = .{ .kind = .{ .print = .{
            .args = try args.toOwnedSlice(self.allocator),
            .output_file = output_file,
            .append = append,
        } } };
        return stmt;
    }

    fn parsePrintf(self: *Parser) ParseError!*ast.Statement {
        self.advance(); // consume 'printf'

        const format = try self.parseExpression();

        var args = std.ArrayListUnmanaged(*ast.Expression){};
        defer args.deinit(self.allocator);

        while (self.match(.comma)) {
            const arg = try self.parseExpression();
            try args.append(self.allocator, arg);
        }

        var output_file: ?*ast.Expression = null;
        var append = false;

        if (self.match(.gt)) {
            output_file = try self.parseExpression();
        } else if (self.match(.append)) {
            output_file = try self.parseExpression();
            append = true;
        }

        self.consumeStatementEnd();

        const stmt = try self.allocator.create(ast.Statement);
        stmt.* = .{ .kind = .{ .printf = .{
            .format = format,
            .args = try args.toOwnedSlice(self.allocator),
            .output_file = output_file,
            .append = append,
        } } };
        return stmt;
    }

    // Expression parsing using precedence climbing
    fn parseExpression(self: *Parser) ParseError!*ast.Expression {
        return self.parseAssignment();
    }

    fn parseAssignment(self: *Parser) ParseError!*ast.Expression {
        const expr = try self.parseTernary();

        if (self.check(.assign) or self.check(.plus_assign) or self.check(.minus_assign) or
            self.check(.star_assign) or self.check(.slash_assign) or
            self.check(.percent_assign) or self.check(.caret_assign))
        {
            const op_kind = self.current.kind;
            self.advance();

            const assign_op: ?ast.AssignOp = switch (op_kind) {
                .assign => null,
                .plus_assign => .add_assign,
                .minus_assign => .sub_assign,
                .star_assign => .mul_assign,
                .slash_assign => .div_assign,
                .percent_assign => .mod_assign,
                .caret_assign => .pow_assign,
                else => null,
            };

            const value = try self.parseAssignment();

            const result = try self.allocator.create(ast.Expression);
            result.* = .{ .kind = .{ .assignment = .{
                .target = expr,
                .value = value,
                .op = assign_op,
            } } };
            return result;
        }

        return expr;
    }

    fn parseTernary(self: *Parser) ParseError!*ast.Expression {
        const expr = try self.parseOr();

        if (self.match(.question)) {
            const true_expr = try self.parseExpression();
            try self.consume(.colon, "Expected ':' in ternary expression");
            const false_expr = try self.parseTernary();

            const result = try self.allocator.create(ast.Expression);
            result.* = .{ .kind = .{ .ternary = .{
                .condition = expr,
                .true_expr = true_expr,
                .false_expr = false_expr,
            } } };
            return result;
        }

        return expr;
    }

    fn parseOr(self: *Parser) ParseError!*ast.Expression {
        var expr = try self.parseAnd();

        while (self.match(.pipepipe)) {
            const right = try self.parseAnd();
            expr = try ast.Expression.binaryOp(self.allocator, .@"or", expr, right);
        }

        return expr;
    }

    fn parseAnd(self: *Parser) ParseError!*ast.Expression {
        var expr = try self.parseIn();

        while (self.match(.ampamp)) {
            const right = try self.parseIn();
            expr = try ast.Expression.binaryOp(self.allocator, .@"and", expr, right);
        }

        return expr;
    }

    fn parseIn(self: *Parser) ParseError!*ast.Expression {
        const expr = try self.parseMatch();

        if (self.match(.kw_in)) {
            try self.consume(.identifier, "Expected array name after 'in'");
            const array_name = self.previous.lexeme;

            const result = try self.allocator.create(ast.Expression);
            result.* = .{ .kind = .{ .in_expr = .{
                .key = expr,
                .array = array_name,
            } } };
            return result;
        }

        return expr;
    }

    fn parseMatch(self: *Parser) ParseError!*ast.Expression {
        var expr = try self.parseComparison();

        while (self.check(.match) or self.check(.not_match)) {
            const negated = self.current.kind == .not_match;
            self.advance();
            const pattern = try self.parseComparison();

            const result = try self.allocator.create(ast.Expression);
            result.* = .{ .kind = .{ .regex_match = .{
                .string = expr,
                .pattern = pattern,
                .negated = negated,
            } } };
            expr = result;
        }

        return expr;
    }

    fn parseComparison(self: *Parser) ParseError!*ast.Expression {
        var expr = try self.parseConcatenation();

        while (self.check(.lt) or self.check(.le) or self.check(.gt) or
            self.check(.ge) or self.check(.eq) or self.check(.ne))
        {
            const op: ast.BinaryOp = switch (self.current.kind) {
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                .ge => .ge,
                .eq => .eq,
                .ne => .ne,
                else => unreachable,
            };
            self.advance();
            const right = try self.parseConcatenation();
            expr = try ast.Expression.binaryOp(self.allocator, op, expr, right);
        }

        return expr;
    }

    fn parseConcatenation(self: *Parser) ParseError!*ast.Expression {
        var expr = try self.parseAddition();

        // AWK's implicit string concatenation - if we see a primary expression
        // after a primary expression with no operator, it's concatenation
        while (self.checkPrimary()) {
            const right = try self.parseAddition();
            const result = try self.allocator.create(ast.Expression);
            result.* = .{ .kind = .{ .concat = .{
                .left = expr,
                .right = right,
            } } };
            expr = result;
        }

        return expr;
    }

    fn parseAddition(self: *Parser) ParseError!*ast.Expression {
        var expr = try self.parseMultiplication();

        while (self.check(.plus) or self.check(.minus)) {
            const op: ast.BinaryOp = if (self.current.kind == .plus) .add else .sub;
            self.advance();
            const right = try self.parseMultiplication();
            expr = try ast.Expression.binaryOp(self.allocator, op, expr, right);
        }

        return expr;
    }

    fn parseMultiplication(self: *Parser) ParseError!*ast.Expression {
        var expr = try self.parsePower();

        while (self.check(.star) or self.check(.slash) or self.check(.percent)) {
            const op: ast.BinaryOp = switch (self.current.kind) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => unreachable,
            };
            self.advance();
            const right = try self.parsePower();
            expr = try ast.Expression.binaryOp(self.allocator, op, expr, right);
        }

        return expr;
    }

    fn parsePower(self: *Parser) ParseError!*ast.Expression {
        var expr = try self.parseUnary();

        if (self.match(.caret)) {
            const right = try self.parsePower(); // Right associative
            expr = try ast.Expression.binaryOp(self.allocator, .pow, expr, right);
        }

        return expr;
    }

    fn parseUnary(self: *Parser) ParseError!*ast.Expression {
        if (self.match(.bang)) {
            const operand = try self.parseUnary();
            const result = try self.allocator.create(ast.Expression);
            result.* = .{ .kind = .{ .unary_op = .{
                .op = .not,
                .operand = operand,
                .prefix = true,
            } } };
            return result;
        }

        if (self.match(.minus)) {
            const operand = try self.parseUnary();
            const result = try self.allocator.create(ast.Expression);
            result.* = .{ .kind = .{ .unary_op = .{
                .op = .negate,
                .operand = operand,
                .prefix = true,
            } } };
            return result;
        }

        if (self.match(.plusplus)) {
            const operand = try self.parseUnary();
            const result = try self.allocator.create(ast.Expression);
            result.* = .{ .kind = .{ .unary_op = .{
                .op = .pre_incr,
                .operand = operand,
                .prefix = true,
            } } };
            return result;
        }

        if (self.match(.minusminus)) {
            const operand = try self.parseUnary();
            const result = try self.allocator.create(ast.Expression);
            result.* = .{ .kind = .{ .unary_op = .{
                .op = .pre_decr,
                .operand = operand,
                .prefix = true,
            } } };
            return result;
        }

        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!*ast.Expression {
        var expr = try self.parsePrimary();

        while (true) {
            if (self.match(.plusplus)) {
                const result = try self.allocator.create(ast.Expression);
                result.* = .{ .kind = .{ .unary_op = .{
                    .op = .post_incr,
                    .operand = expr,
                    .prefix = false,
                } } };
                expr = result;
            } else if (self.match(.minusminus)) {
                const result = try self.allocator.create(ast.Expression);
                result.* = .{ .kind = .{ .unary_op = .{
                    .op = .post_decr,
                    .operand = expr,
                    .prefix = false,
                } } };
                expr = result;
            } else if (self.match(.lbracket)) {
                // Array subscript
                const index = try self.parseExpression();
                try self.consume(.rbracket, "Expected ']' after subscript");

                // Extract array name from expr
                switch (expr.kind) {
                    .variable => |name| {
                        self.allocator.destroy(expr);
                        const result = try self.allocator.create(ast.Expression);
                        result.* = .{ .kind = .{ .array_subscript = .{
                            .array = name,
                            .index = index,
                        } } };
                        expr = result;
                    },
                    else => return ParseError.UnexpectedToken,
                }
            } else {
                break;
            }
        }

        return expr;
    }

    fn parsePrimary(self: *Parser) ParseError!*ast.Expression {
        // Number literal
        if (self.match(.number)) {
            const n = std.fmt.parseFloat(f64, self.previous.lexeme) catch 0.0;
            return ast.Expression.numberLiteral(self.allocator, n);
        }

        // String literal
        if (self.match(.string)) {
            // Strip quotes
            const lexeme = self.previous.lexeme;
            const content = if (lexeme.len >= 2) lexeme[1 .. lexeme.len - 1] else lexeme;
            return ast.Expression.stringLiteral(self.allocator, content);
        }

        // Regex literal
        if (self.match(.regex)) {
            const lexeme = self.previous.lexeme;
            const pattern = if (lexeme.len >= 2) lexeme[1 .. lexeme.len - 1] else lexeme;
            const result = try self.allocator.create(ast.Expression);
            result.* = .{ .kind = .{ .regex_literal = pattern } };
            return result;
        }

        // Field reference: $N or $(expr)
        if (self.match(.dollar)) {
            if (self.match(.number)) {
                const n = std.fmt.parseFloat(f64, self.previous.lexeme) catch 0.0;
                if (n == 0) {
                    const result = try self.allocator.create(ast.Expression);
                    result.* = .{ .kind = .whole_line };
                    return result;
                }
                const index = try ast.Expression.numberLiteral(self.allocator, n);
                return ast.Expression.fieldRef(self.allocator, index);
            } else if (self.match(.lparen)) {
                const index = try self.parseExpression();
                try self.consume(.rparen, "Expected ')' after field expression");
                return ast.Expression.fieldRef(self.allocator, index);
            } else if (self.match(.identifier)) {
                const var_ref = try ast.Expression.variableRef(self.allocator, self.previous.lexeme);
                return ast.Expression.fieldRef(self.allocator, var_ref);
            } else {
                return ParseError.UnexpectedToken;
            }
        }

        // Identifier (variable or function call)
        if (self.match(.identifier)) {
            const name = self.previous.lexeme;

            // Check for function call
            if (self.match(.lparen)) {
                var args = std.ArrayListUnmanaged(*ast.Expression){};
                defer args.deinit(self.allocator);

                if (!self.check(.rparen)) {
                    while (true) {
                        const arg = try self.parseExpression();
                        try args.append(self.allocator, arg);
                        if (!self.match(.comma)) break;
                    }
                }
                try self.consume(.rparen, "Expected ')' after arguments");

                const result = try self.allocator.create(ast.Expression);
                result.* = .{ .kind = .{ .function_call = .{
                    .name = name,
                    .args = try args.toOwnedSlice(self.allocator),
                } } };
                return result;
            }

            return ast.Expression.variableRef(self.allocator, name);
        }

        // Parenthesized expression
        if (self.match(.lparen)) {
            const expr = try self.parseExpression();
            try self.consume(.rparen, "Expected ')' after expression");
            return expr;
        }

        return ParseError.UnexpectedToken;
    }

    fn checkPrimary(self: *Parser) bool {
        return self.check(.number) or self.check(.string) or self.check(.regex) or
            self.check(.dollar) or self.check(.identifier) or self.check(.lparen);
    }

    // Helper functions
    fn advance(self: *Parser) void {
        self.previous = self.current;
        self.current = self.tokenizer.next();
    }

    fn check(self: *const Parser, kind: Token.Kind) bool {
        return self.current.kind == kind;
    }

    fn match(self: *Parser, kind: Token.Kind) bool {
        if (!self.check(kind)) return false;
        self.advance();
        return true;
    }

    fn consume(self: *Parser, kind: Token.Kind, _: []const u8) ParseError!void {
        if (self.check(kind)) {
            self.advance();
            return;
        }
        return ParseError.UnexpectedToken;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.match(.newline) or self.match(.semicolon)) {}
    }

    fn checkStatementEnd(self: *const Parser) bool {
        return self.check(.newline) or self.check(.semicolon) or self.check(.rbrace) or self.check(.eof);
    }

    fn consumeStatementEnd(self: *Parser) void {
        _ = self.match(.newline) or self.match(.semicolon);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Tokenizer: simple tokens" {
    var tokenizer = Tokenizer.init("+ - * / % ^");

    try std.testing.expectEqual(Token.Kind.plus, tokenizer.next().kind);
    try std.testing.expectEqual(Token.Kind.minus, tokenizer.next().kind);
    try std.testing.expectEqual(Token.Kind.star, tokenizer.next().kind);
    try std.testing.expectEqual(Token.Kind.slash, tokenizer.next().kind);
    try std.testing.expectEqual(Token.Kind.percent, tokenizer.next().kind);
    try std.testing.expectEqual(Token.Kind.caret, tokenizer.next().kind);
}

test "Tokenizer: keywords" {
    var tokenizer = Tokenizer.init("BEGIN END if else while for");

    try std.testing.expectEqual(Token.Kind.kw_begin, tokenizer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_end, tokenizer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_if, tokenizer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_else, tokenizer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_while, tokenizer.next().kind);
    try std.testing.expectEqual(Token.Kind.kw_for, tokenizer.next().kind);
}

test "Tokenizer: numbers and strings" {
    var tokenizer = Tokenizer.init("42 3.14 \"hello\"");

    const num1 = tokenizer.next();
    try std.testing.expectEqual(Token.Kind.number, num1.kind);
    try std.testing.expectEqualStrings("42", num1.lexeme);

    const num2 = tokenizer.next();
    try std.testing.expectEqual(Token.Kind.number, num2.kind);

    const str = tokenizer.next();
    try std.testing.expectEqual(Token.Kind.string, str.kind);
}

test "Parser: simple print" {
    const allocator = std.testing.allocator;
    var parser = Parser.init("{ print $1 }", allocator);
    var program = try parser.parse();
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 1), program.rules.len);
}

test "Parser: BEGIN block" {
    const allocator = std.testing.allocator;
    var parser = Parser.init("BEGIN { x = 5 }", allocator);
    var program = try parser.parse();
    defer program.deinit();

    try std.testing.expect(program.begin != null);
}
