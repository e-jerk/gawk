const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");

const AwkOptions = gpu.AwkOptions;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n====== GAWK SMOKE TESTS ======\n\n", .{});

    var passed: u32 = 0;
    var failed: u32 = 0;

    // Test 1: Basic pattern matching
    {
        const text = "hello world\nerror occurred\nall is well\nerror again\n";
        const pattern = "error";
        const options = AwkOptions{};

        var result = try cpu.processAwk(text, pattern, options, allocator);
        defer result.deinit();

        if (result.matches.len == 2) {
            std.debug.print("Test 1: Basic pattern matching - PASS\n", .{});
            passed += 1;
        } else {
            std.debug.print("Test 1: Basic pattern matching - FAIL (expected 2, got {d})\n", .{result.matches.len});
            failed += 1;
        }
    }

    // Test 2: Case-insensitive matching
    {
        const text = "Hello World\nHELLO WORLD\nhello world\n";
        const pattern = "hello";
        const options = AwkOptions{ .case_insensitive = true };

        var result = try cpu.processAwk(text, pattern, options, allocator);
        defer result.deinit();

        if (result.matches.len == 3) {
            std.debug.print("Test 2: Case-insensitive matching - PASS\n", .{});
            passed += 1;
        } else {
            std.debug.print("Test 2: Case-insensitive matching - FAIL (expected 3, got {d})\n", .{result.matches.len});
            failed += 1;
        }
    }

    // Test 3: Field splitting (default whitespace)
    {
        const text = "one two three\nfour five six\n";
        const pattern = "";
        const options = AwkOptions{};

        var result = try cpu.processAwk(text, pattern, options, allocator);
        defer result.deinit();

        // Should have 2 lines with 3 fields each = 6 fields total
        if (result.fields.len == 6) {
            std.debug.print("Test 3: Field splitting (whitespace) - PASS\n", .{});
            passed += 1;
        } else {
            std.debug.print("Test 3: Field splitting (whitespace) - FAIL (expected 6 fields, got {d})\n", .{result.fields.len});
            failed += 1;
        }
    }

    // Test 4: Custom field separator (colon)
    {
        const text = "root:x:0:0\nbin:x:1:1\n";
        const pattern = "";
        const options = AwkOptions{ .field_separator = ":" };

        var result = try cpu.processAwk(text, pattern, options, allocator);
        defer result.deinit();

        // Should have 2 lines with 4 fields each = 8 fields total
        if (result.fields.len == 8) {
            std.debug.print("Test 4: Custom field separator - PASS\n", .{});
            passed += 1;
        } else {
            std.debug.print("Test 4: Custom field separator - FAIL (expected 8 fields, got {d})\n", .{result.fields.len});
            failed += 1;
        }
    }

    // Test 5: Invert match
    {
        const text = "good line\nbad line\nanother good\n";
        const pattern = "bad";
        const options = AwkOptions{ .invert_match = true };

        var result = try cpu.processAwk(text, pattern, options, allocator);
        defer result.deinit();

        if (result.matches.len == 2) {
            std.debug.print("Test 5: Invert match - PASS\n", .{});
            passed += 1;
        } else {
            std.debug.print("Test 5: Invert match - FAIL (expected 2, got {d})\n", .{result.matches.len});
            failed += 1;
        }
    }

    // Test 6: Pattern + field extraction
    {
        const text = "ERROR code 500\nINFO code 200\nERROR code 404\n";
        const pattern = "ERROR";
        const options = AwkOptions{};

        var result = try cpu.processAwk(text, pattern, options, allocator);
        defer result.deinit();

        // Should match 2 lines with ERROR
        if (result.matches.len == 2) {
            std.debug.print("Test 6: Pattern + fields - PASS\n", .{});
            passed += 1;
        } else {
            std.debug.print("Test 6: Pattern + fields - FAIL (expected 2, got {d})\n", .{result.matches.len});
            failed += 1;
        }
    }

    // Test 7: Empty pattern (match all)
    {
        const text = "line one\nline two\nline three\n";
        const pattern = "";
        const options = AwkOptions{};

        var result = try cpu.processAwk(text, pattern, options, allocator);
        defer result.deinit();

        if (result.matches.len == 3) {
            std.debug.print("Test 7: Empty pattern (match all) - PASS\n", .{});
            passed += 1;
        } else {
            std.debug.print("Test 7: Empty pattern (match all) - FAIL (expected 3, got {d})\n", .{result.matches.len});
            failed += 1;
        }
    }

    // Test 8: gsub substitution
    {
        const text = "hello world world";
        const pattern = "world";
        const options = AwkOptions{};

        const subs = try cpu.findSubstitutions(text, pattern, options, allocator);
        defer allocator.free(subs);

        if (subs.len == 2) {
            std.debug.print("Test 8: gsub find matches - PASS\n", .{});
            passed += 1;
        } else {
            std.debug.print("Test 8: gsub find matches - FAIL (expected 2, got {d})\n", .{subs.len});
            failed += 1;
        }

        const replaced = try cpu.applySubstitutions(text, subs, pattern.len, "universe", allocator);
        defer allocator.free(replaced);

        if (std.mem.eql(u8, replaced, "hello universe universe")) {
            std.debug.print("Test 9: gsub apply - PASS\n", .{});
            passed += 1;
        } else {
            std.debug.print("Test 9: gsub apply - FAIL (got '{s}')\n", .{replaced});
            failed += 1;
        }
    }

    // Test 10: No matches
    {
        const text = "hello world\n";
        const pattern = "xyz";
        const options = AwkOptions{};

        var result = try cpu.processAwk(text, pattern, options, allocator);
        defer result.deinit();

        if (result.matches.len == 0) {
            std.debug.print("Test 10: No matches - PASS\n", .{});
            passed += 1;
        } else {
            std.debug.print("Test 10: No matches - FAIL (expected 0, got {d})\n", .{result.matches.len});
            failed += 1;
        }
    }

    // GPU tests (if available)
    if (build_options.is_macos) {
        std.debug.print("\n--- Metal GPU Tests ---\n", .{});
        if (gpu.metal.MetalAwk.init(allocator)) |searcher| {
            defer searcher.deinit();

            const text = "error line one\ngood line\nerror line two\n";
            const pattern = "error";
            const options = AwkOptions{};

            if (searcher.processAwk(text, pattern, options, allocator)) |res| {
                var result = res;
                defer result.deinit();
                if (result.matches.len == 2) {
                    std.debug.print("Metal: Pattern matching - PASS\n", .{});
                    passed += 1;
                } else {
                    std.debug.print("Metal: Pattern matching - FAIL (expected 2, got {d})\n", .{result.matches.len});
                    failed += 1;
                }
            } else |err| {
                std.debug.print("Metal: Pattern matching - FAIL ({s})\n", .{@errorName(err)});
                failed += 1;
            }
        } else |err| {
            std.debug.print("Metal: Init failed ({s}) - SKIP\n", .{@errorName(err)});
        }
    }

    // Vulkan tests
    std.debug.print("\n--- Vulkan GPU Tests ---\n", .{});
    if (gpu.vulkan.VulkanAwk.init(allocator)) |searcher| {
        defer searcher.deinit();

        const text = "error line one\ngood line\nerror line two\n";
        const pattern = "error";
        const options = AwkOptions{};

        if (searcher.processAwk(text, pattern, options, allocator)) |res| {
            var result = res;
            defer result.deinit();
            if (result.matches.len == 2) {
                std.debug.print("Vulkan: Pattern matching - PASS\n", .{});
                passed += 1;
            } else {
                std.debug.print("Vulkan: Pattern matching - FAIL (expected 2, got {d})\n", .{result.matches.len});
                failed += 1;
            }
        } else |err| {
            std.debug.print("Vulkan: Pattern matching - FAIL ({s})\n", .{@errorName(err)});
            failed += 1;
        }
    } else |err| {
        std.debug.print("Vulkan: Init failed ({s}) - SKIP\n", .{@errorName(err)});
    }

    std.debug.print("\n====== SUMMARY ======\n", .{});
    std.debug.print("Passed: {d}\n", .{passed});
    std.debug.print("Failed: {d}\n", .{failed});

    if (failed > 0) {
        std.process.exit(1);
    }
}
