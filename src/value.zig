const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// AWK Value Type
// AWK uses a unique dual string/number type system where values can be
// interpreted as either strings or numbers depending on context.
// ============================================================================

pub const Value = struct {
    /// Internal representation
    repr: Repr,

    /// Type flags indicating which representations are valid/cached
    flags: Flags = .{},

    /// Allocator used for string storage
    allocator: ?Allocator = null,

    pub const Repr = union {
        /// String value (owned if allocated)
        string: []const u8,
        /// Numeric value
        number: f64,
        /// Uninitialized / null value
        uninit: void,
    };

    pub const Flags = packed struct {
        has_string: bool = false,
        has_number: bool = false,
        string_owned: bool = false,
        is_numeric_string: bool = false, // String that looks like a number
        _padding: u4 = 0,
    };

    // ------------------------------------------------------------------------
    // Constructors
    // ------------------------------------------------------------------------

    pub fn initNumber(n: f64) Value {
        return .{
            .repr = .{ .number = n },
            .flags = .{ .has_number = true },
        };
    }

    pub fn initString(s: []const u8) Value {
        return .{
            .repr = .{ .string = s },
            .flags = .{ .has_string = true },
        };
    }

    pub fn initStringOwned(s: []const u8, allocator: Allocator) Value {
        return .{
            .repr = .{ .string = s },
            .flags = .{ .has_string = true, .string_owned = true },
            .allocator = allocator,
        };
    }

    pub fn initUninit() Value {
        return .{
            .repr = .{ .uninit = {} },
            .flags = .{},
        };
    }

    /// Empty string value (AWK's default for uninitialized variables)
    pub fn initEmpty() Value {
        return .{
            .repr = .{ .string = "" },
            .flags = .{ .has_string = true, .has_number = true },
        };
    }

    // ------------------------------------------------------------------------
    // Accessors
    // ------------------------------------------------------------------------

    /// Get value as a number, converting from string if necessary
    pub fn asNumber(self: *const Value) f64 {
        if (self.flags.has_number) {
            return self.repr.number;
        }

        if (self.flags.has_string) {
            return stringToNumber(self.repr.string);
        }

        return 0.0;
    }

    /// Get value as a string, converting from number if necessary
    /// Returns a slice that may be temporary - caller should copy if needed
    pub fn asString(self: *const Value, allocator: Allocator) ![]const u8 {
        if (self.flags.has_string) {
            return self.repr.string;
        }

        if (self.flags.has_number) {
            return numberToString(self.repr.number, allocator);
        }

        return "";
    }

    /// Get string without allocation (returns "" if value is numeric only)
    pub fn asStringDirect(self: *const Value) []const u8 {
        if (self.flags.has_string) {
            return self.repr.string;
        }
        return "";
    }

    /// Check if value is truthy (non-zero number or non-empty string)
    pub fn isTruthy(self: *const Value) bool {
        if (self.flags.has_number) {
            return self.repr.number != 0.0;
        }
        if (self.flags.has_string) {
            return self.repr.string.len > 0;
        }
        return false;
    }

    /// Check if value is empty/uninitialized
    pub fn isEmpty(self: *const Value) bool {
        if (self.flags.has_string) {
            return self.repr.string.len == 0;
        }
        if (self.flags.has_number) {
            return self.repr.number == 0.0;
        }
        return true;
    }

    // ------------------------------------------------------------------------
    // Type Coercion
    // ------------------------------------------------------------------------

    /// Check if string looks like a number (for comparison purposes)
    pub fn looksLikeNumber(s: []const u8) bool {
        if (s.len == 0) return false;

        var i: usize = 0;

        // Skip leading whitespace
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
        if (i >= s.len) return false;

        // Optional sign
        if (s[i] == '+' or s[i] == '-') i += 1;
        if (i >= s.len) return false;

        // Must have at least one digit or decimal point followed by digit
        var has_digit = false;

        // Integer part
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            has_digit = true;
        }

        // Decimal part
        if (i < s.len and s[i] == '.') {
            i += 1;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                has_digit = true;
            }
        }

        if (!has_digit) return false;

        // Exponent part
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
            if (i >= s.len) return false;

            var exp_has_digit = false;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                exp_has_digit = true;
            }
            if (!exp_has_digit) return false;
        }

        // Skip trailing whitespace
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}

        return i == s.len;
    }

    // ------------------------------------------------------------------------
    // Comparison Operations
    // ------------------------------------------------------------------------

    pub const CompareOp = enum {
        lt, // <
        le, // <=
        gt, // >
        ge, // >=
        eq, // ==
        ne, // !=
    };

    /// Compare two values following AWK semantics
    /// If both look like numbers, compare numerically; otherwise compare as strings
    pub fn compare(a: *const Value, b: *const Value, op: CompareOp) bool {
        const a_numeric = a.flags.has_number or (a.flags.has_string and looksLikeNumber(a.repr.string));
        const b_numeric = b.flags.has_number or (b.flags.has_string and looksLikeNumber(b.repr.string));

        if (a_numeric and b_numeric) {
            // Numeric comparison
            const an = a.asNumber();
            const bn = b.asNumber();
            return switch (op) {
                .lt => an < bn,
                .le => an <= bn,
                .gt => an > bn,
                .ge => an >= bn,
                .eq => an == bn,
                .ne => an != bn,
            };
        } else {
            // String comparison
            const as = a.asStringDirect();
            const bs = b.asStringDirect();
            const cmp = std.mem.order(u8, as, bs);
            return switch (op) {
                .lt => cmp == .lt,
                .le => cmp != .gt,
                .gt => cmp == .gt,
                .ge => cmp != .lt,
                .eq => cmp == .eq,
                .ne => cmp != .eq,
            };
        }
    }

    // ------------------------------------------------------------------------
    // Arithmetic Operations
    // ------------------------------------------------------------------------

    pub fn add(a: *const Value, b: *const Value) Value {
        return initNumber(a.asNumber() + b.asNumber());
    }

    pub fn sub(a: *const Value, b: *const Value) Value {
        return initNumber(a.asNumber() - b.asNumber());
    }

    pub fn mul(a: *const Value, b: *const Value) Value {
        return initNumber(a.asNumber() * b.asNumber());
    }

    pub fn div(a: *const Value, b: *const Value) Value {
        const bn = b.asNumber();
        if (bn == 0.0) {
            return initNumber(std.math.inf(f64));
        }
        return initNumber(a.asNumber() / bn);
    }

    pub fn mod(a: *const Value, b: *const Value) Value {
        const an = a.asNumber();
        const bn = b.asNumber();
        if (bn == 0.0) {
            return initNumber(std.math.nan(f64));
        }
        return initNumber(@mod(an, bn));
    }

    pub fn pow(a: *const Value, b: *const Value) Value {
        return initNumber(std.math.pow(f64, a.asNumber(), b.asNumber()));
    }

    pub fn negate(self: *const Value) Value {
        return initNumber(-self.asNumber());
    }

    pub fn increment(self: *const Value) Value {
        return initNumber(self.asNumber() + 1.0);
    }

    pub fn decrement(self: *const Value) Value {
        return initNumber(self.asNumber() - 1.0);
    }

    // ------------------------------------------------------------------------
    // String Operations
    // ------------------------------------------------------------------------

    /// Concatenate two values as strings
    pub fn concat(a: *const Value, b: *const Value, allocator: Allocator) !Value {
        const as = try a.asString(allocator);
        const bs = try b.asString(allocator);

        const result = try allocator.alloc(u8, as.len + bs.len);
        @memcpy(result[0..as.len], as);
        @memcpy(result[as.len..], bs);

        return initStringOwned(result, allocator);
    }

    /// Get string length
    pub fn length(self: *const Value) f64 {
        if (self.flags.has_string) {
            return @floatFromInt(self.repr.string.len);
        }
        return 0.0;
    }

    // ------------------------------------------------------------------------
    // Memory Management
    // ------------------------------------------------------------------------

    pub fn deinit(self: *Value) void {
        if (self.flags.string_owned and self.allocator != null) {
            self.allocator.?.free(self.repr.string);
        }
        self.* = initUninit();
    }

    pub fn clone(self: *const Value, allocator: Allocator) !Value {
        if (self.flags.has_string and self.repr.string.len > 0) {
            const copy = try allocator.dupe(u8, self.repr.string);
            return initStringOwned(copy, allocator);
        }
        if (self.flags.has_number) {
            return initNumber(self.repr.number);
        }
        return initEmpty();
    }

    // ------------------------------------------------------------------------
    // Helper Functions
    // ------------------------------------------------------------------------

    fn stringToNumber(s: []const u8) f64 {
        if (s.len == 0) return 0.0;

        // Skip leading whitespace
        var i: usize = 0;
        while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
        if (i >= s.len) return 0.0;

        // Parse the number
        const result = std.fmt.parseFloat(f64, s[i..]) catch return 0.0;
        return result;
    }

    fn numberToString(n: f64, allocator: Allocator) ![]const u8 {
        // AWK uses OFMT for output format, default is "%.6g"
        // For now, use a reasonable default
        if (n == @trunc(n) and @abs(n) < 1e15) {
            // Integer-like, format without decimal
            const i: i64 = @intFromFloat(n);
            return std.fmt.allocPrint(allocator, "{d}", .{i});
        }
        return std.fmt.allocPrint(allocator, "{d:.6}", .{n});
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Value: number creation and access" {
    const v = Value.initNumber(42.0);
    try std.testing.expectEqual(@as(f64, 42.0), v.asNumber());
}

test "Value: string creation and access" {
    const v = Value.initString("hello");
    try std.testing.expectEqualStrings("hello", v.asStringDirect());
}

test "Value: string to number conversion" {
    const v = Value.initString("123.45");
    try std.testing.expectApproxEqAbs(@as(f64, 123.45), v.asNumber(), 0.001);
}

test "Value: empty string to number" {
    const v = Value.initString("");
    try std.testing.expectEqual(@as(f64, 0.0), v.asNumber());
}

test "Value: numeric comparison" {
    const a = Value.initNumber(10.0);
    const b = Value.initNumber(5.0);

    try std.testing.expect(Value.compare(&a, &b, .gt));
    try std.testing.expect(Value.compare(&b, &a, .lt));
    try std.testing.expect(Value.compare(&a, &a, .eq));
}

test "Value: string comparison" {
    const a = Value.initString("apple");
    const b = Value.initString("banana");

    try std.testing.expect(Value.compare(&a, &b, .lt));
    try std.testing.expect(Value.compare(&b, &a, .gt));
}

test "Value: arithmetic operations" {
    const a = Value.initNumber(10.0);
    const b = Value.initNumber(3.0);

    try std.testing.expectEqual(@as(f64, 13.0), Value.add(&a, &b).asNumber());
    try std.testing.expectEqual(@as(f64, 7.0), Value.sub(&a, &b).asNumber());
    try std.testing.expectEqual(@as(f64, 30.0), Value.mul(&a, &b).asNumber());
    try std.testing.expectApproxEqAbs(@as(f64, 3.333), Value.div(&a, &b).asNumber(), 0.01);
    try std.testing.expectEqual(@as(f64, 1.0), Value.mod(&a, &b).asNumber());
}

test "Value: looksLikeNumber" {
    try std.testing.expect(Value.looksLikeNumber("123"));
    try std.testing.expect(Value.looksLikeNumber("-123.45"));
    try std.testing.expect(Value.looksLikeNumber("1.5e10"));
    try std.testing.expect(Value.looksLikeNumber("  42  "));
    try std.testing.expect(!Value.looksLikeNumber("abc"));
    try std.testing.expect(!Value.looksLikeNumber(""));
    try std.testing.expect(!Value.looksLikeNumber("12abc"));
}

test "Value: truthiness" {
    const zero = Value.initNumber(0.0);
    const nonzero = Value.initNumber(42.0);
    const empty = Value.initString("");
    const nonempty = Value.initString("hello");

    try std.testing.expect(!zero.isTruthy());
    try std.testing.expect(nonzero.isTruthy());
    try std.testing.expect(!empty.isTruthy());
    try std.testing.expect(nonempty.isTruthy());
}
