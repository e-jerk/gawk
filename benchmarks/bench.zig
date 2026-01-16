const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");
const cpu_gnu = @import("cpu_gnu");

const AwkOptions = gpu.AwkOptions;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Default parameters
    var file_size: usize = 10 * 1024 * 1024; // 10MB
    var pattern: []const u8 = "the";
    var iterations: usize = 5;
    var run_regex: bool = false;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--size") and i + 1 < args.len) {
            i += 1;
            file_size = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--pattern") and i + 1 < args.len) {
            i += 1;
            pattern = args[i];
        } else if (std.mem.eql(u8, args[i], "--iterations") and i + 1 < args.len) {
            i += 1;
            iterations = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--regex")) {
            run_regex = true;
        }
    }

    std.debug.print("\n====== GAWK BENCHMARK ======\n\n", .{});
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Data size:   {d:.2} MB\n", .{@as(f64, @floatFromInt(file_size)) / (1024 * 1024)});
    std.debug.print("  Pattern:     \"{s}\"\n", .{pattern});
    std.debug.print("  Iterations:  {d}\n\n", .{iterations});

    // Generate test data
    std.debug.print("Generating test data...\n", .{});
    const text = try generateTestData(allocator, file_size);
    defer allocator.free(text);

    const options = AwkOptions{};

    // Warm up and count matches
    var warmup_result = try cpu.processAwk(text, pattern, options, allocator);
    const expected_matches = warmup_result.matches.len;
    warmup_result.deinit();

    std.debug.print("Expected matches: {d}\n\n", .{expected_matches});

    // CPU (Optimized) benchmark
    std.debug.print("Benchmarking CPU (Optimized)...\n", .{});
    const cpu_times = try benchmarkCpu(text, pattern, options, allocator, iterations);
    defer allocator.free(cpu_times);

    // CPU (GNU) benchmark
    std.debug.print("Benchmarking CPU (GNU)...\n", .{});
    const cpu_gnu_times = try benchmarkCpuGnu(text, pattern, options, allocator, iterations);
    defer if (cpu_gnu_times) |t| allocator.free(t);

    // Metal benchmark
    var metal_times: ?[]u64 = null;
    var metal_matches: u64 = 0;
    if (build_options.is_macos) {
        std.debug.print("Benchmarking Metal...\n", .{});
        const metal_result = benchmarkMetal(text, pattern, options, allocator, iterations) catch |err| blk: {
            std.debug.print("Metal benchmark failed: {}\n", .{err});
            break :blk null;
        };
        if (metal_result) |result| {
            metal_times = result.times;
            metal_matches = result.matches;
        }
    }
    defer if (metal_times) |t| allocator.free(t);

    // Vulkan benchmark
    std.debug.print("Benchmarking Vulkan...\n", .{});
    var vulkan_times: ?[]u64 = null;
    var vulkan_matches: u64 = 0;
    const vulkan_result = benchmarkVulkan(text, pattern, options, allocator, iterations) catch |err| blk: {
        std.debug.print("Vulkan benchmark failed: {}\n", .{err});
        break :blk null;
    };
    if (vulkan_result) |result| {
        vulkan_times = result.times;
        vulkan_matches = result.matches;
    }
    defer if (vulkan_times) |t| allocator.free(t);

    // Print results
    std.debug.print("\n====== RESULTS ======\n\n", .{});
    std.debug.print("{s:<12} {s:>12} {s:>12} {s:>12} {s:>10}\n", .{ "Backend", "Avg (ms)", "Min (ms)", "Throughput", "Speedup" });
    std.debug.print("{s:<12} {s:>12} {s:>12} {s:>12} {s:>10}\n", .{ "------------", "------------", "------------", "------------", "----------" });

    const cpu_avg = average(cpu_times);
    const cpu_min = minimum(cpu_times);
    const cpu_throughput = @as(f64, @floatFromInt(file_size)) / (cpu_avg / 1000.0) / (1024 * 1024);

    std.debug.print("{s:<12} {d:>12.1} {d:>12.1} {d:>9.1} MB/s {d:>9.1}x\n", .{ "CPU-Optimized", cpu_avg, cpu_min, cpu_throughput, 1.0 });

    if (cpu_gnu_times) |times| {
        const gnu_avg = average(times);
        const gnu_min = minimum(times);
        const gnu_throughput = @as(f64, @floatFromInt(file_size)) / (gnu_avg / 1000.0) / (1024 * 1024);
        const gnu_speedup = cpu_avg / gnu_avg;
        std.debug.print("{s:<12} {d:>12.1} {d:>12.1} {d:>9.1} MB/s {d:>9.1}x\n", .{ "CPU-GNU", gnu_avg, gnu_min, gnu_throughput, gnu_speedup });
    }

    if (metal_times) |times| {
        const metal_avg = average(times);
        const metal_min = minimum(times);
        const metal_throughput = @as(f64, @floatFromInt(file_size)) / (metal_avg / 1000.0) / (1024 * 1024);
        const metal_speedup = cpu_avg / metal_avg;
        std.debug.print("{s:<12} {d:>12.1} {d:>12.1} {d:>9.1} MB/s {d:>9.1}x\n", .{ "Metal", metal_avg, metal_min, metal_throughput, metal_speedup });
    }

    if (vulkan_times) |times| {
        const vulkan_avg = average(times);
        const vulkan_min = minimum(times);
        const vulkan_throughput = @as(f64, @floatFromInt(file_size)) / (vulkan_avg / 1000.0) / (1024 * 1024);
        const vulkan_speedup = cpu_avg / vulkan_avg;
        std.debug.print("{s:<12} {d:>12.1} {d:>12.1} {d:>9.1} MB/s {d:>9.1}x\n", .{ "Vulkan", vulkan_avg, vulkan_min, vulkan_throughput, vulkan_speedup });
    }

    // Correctness check
    std.debug.print("\n====== CORRECTNESS CHECK ======\n\n", .{});

    var cpu_result = try cpu.processAwk(text, pattern, options, allocator);
    defer cpu_result.deinit();
    std.debug.print("CPU-Optimized: {d} matches - {s}\n", .{ cpu_result.matches.len, if (cpu_result.matches.len == expected_matches) "PASS" else "FAIL" });

    // GNU correctness check
    if (cpu_gnu.processAwk(text, pattern, options, allocator)) |gnu_res| {
        var gnu_result = gnu_res;
        defer gnu_result.deinit();
        std.debug.print("CPU-GNU:       {d} matches - {s}\n", .{ gnu_result.matches.len, if (gnu_result.matches.len == expected_matches) "PASS" else "FAIL" });
    } else |_| {
        std.debug.print("CPU-GNU:       unavailable\n", .{});
    }

    if (build_options.is_macos) {
        std.debug.print("Metal:  {d} matches - {s}\n", .{ metal_matches, if (metal_matches == expected_matches) "PASS" else "FAIL" });
    }

    std.debug.print("Vulkan: {d} matches - {s}\n", .{ vulkan_matches, if (vulkan_matches == expected_matches) "PASS" else "FAIL" });

    // Run regex benchmarks if requested
    if (run_regex) {
        try runRegexBenchmarks(allocator, file_size, iterations);
    }
}

fn generateTestData(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const words = [_][]const u8{
        "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
        "hello", "world", "error", "warning", "info", "debug", "trace",
        "user", "system", "process", "thread", "memory", "disk", "network",
    };

    var data = try allocator.alloc(u8, size);
    var pos: usize = 0;
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    while (pos < size) {
        // Generate a line
        const words_per_line = rng.intRangeAtMost(usize, 3, 10);
        for (0..words_per_line) |j| {
            if (pos >= size) break;
            if (j > 0 and pos < size) {
                data[pos] = ' ';
                pos += 1;
            }
            const word = words[rng.intRangeAtMost(usize, 0, words.len - 1)];
            const copy_len = @min(word.len, size - pos);
            @memcpy(data[pos..][0..copy_len], word[0..copy_len]);
            pos += copy_len;
        }
        if (pos < size) {
            data[pos] = '\n';
            pos += 1;
        }
    }

    return data;
}

fn benchmarkCpu(text: []const u8, pattern: []const u8, options: AwkOptions, allocator: std.mem.Allocator, iterations: usize) ![]u64 {
    var times = try allocator.alloc(u64, iterations);

    for (0..iterations) |i| {
        var timer = try std.time.Timer.start();
        var result = try cpu.processAwk(text, pattern, options, allocator);
        times[i] = timer.read() / std.time.ns_per_ms;
        result.deinit();
    }

    return times;
}

fn benchmarkCpuGnu(text: []const u8, pattern: []const u8, options: AwkOptions, allocator: std.mem.Allocator, iterations: usize) !?[]u64 {
    var times = try allocator.alloc(u64, iterations);

    for (0..iterations) |i| {
        var timer = try std.time.Timer.start();
        var result = cpu_gnu.processAwk(text, pattern, options, allocator) catch |err| {
            std.debug.print("GNU processAwk failed: {}\n", .{err});
            allocator.free(times);
            return null;
        };
        times[i] = timer.read() / std.time.ns_per_ms;
        result.deinit();
    }

    return times;
}

const BenchmarkResult = struct {
    times: []u64,
    matches: u64,
};

fn benchmarkMetal(text: []const u8, pattern: []const u8, options: AwkOptions, allocator: std.mem.Allocator, iterations: usize) !?BenchmarkResult {
    if (!build_options.is_macos) return null;

    var searcher = gpu.metal.MetalAwk.init(allocator) catch return null;
    defer searcher.deinit();

    var times = try allocator.alloc(u64, iterations);
    var last_matches: u64 = 0;

    for (0..iterations) |i| {
        var timer = try std.time.Timer.start();
        var result = searcher.processAwk(text, pattern, options, allocator) catch {
            allocator.free(times);
            return null;
        };
        times[i] = timer.read() / std.time.ns_per_ms;
        last_matches = result.matches.len;
        result.deinit();
    }

    return BenchmarkResult{ .times = times, .matches = last_matches };
}

fn benchmarkVulkan(text: []const u8, pattern: []const u8, options: AwkOptions, allocator: std.mem.Allocator, iterations: usize) !?BenchmarkResult {
    var searcher = gpu.vulkan.VulkanAwk.init(allocator) catch return null;
    defer searcher.deinit();

    var times = try allocator.alloc(u64, iterations);
    var last_matches: u64 = 0;

    for (0..iterations) |i| {
        var timer = try std.time.Timer.start();
        var result = searcher.processAwk(text, pattern, options, allocator) catch {
            allocator.free(times);
            return null;
        };
        times[i] = timer.read() / std.time.ns_per_ms;
        last_matches = result.matches.len;
        result.deinit();
    }

    return BenchmarkResult{ .times = times, .matches = last_matches };
}

fn average(times: []u64) f64 {
    var sum: u64 = 0;
    for (times) |t| sum += t;
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(times.len));
}

fn minimum(times: []u64) f64 {
    var min: u64 = std.math.maxInt(u64);
    for (times) |t| if (t < min) {
        min = t;
    };
    return @as(f64, @floatFromInt(min));
}

// ========== REGEX BENCHMARKS ==========

fn benchmarkCpuRegex(text: []const u8, pattern: []const u8, options: AwkOptions, allocator: std.mem.Allocator, iterations: usize) ![]u64 {
    var times = try allocator.alloc(u64, iterations);

    for (0..iterations) |i| {
        var timer = try std.time.Timer.start();
        var result = try cpu.processAwkRegex(text, pattern, options, allocator);
        times[i] = timer.read() / std.time.ns_per_ms;
        result.deinit();
    }

    return times;
}

fn benchmarkMetalRegex(text: []const u8, pattern: []const u8, options: AwkOptions, allocator: std.mem.Allocator, iterations: usize) !?BenchmarkResult {
    if (!build_options.is_macos) return null;

    var searcher = gpu.metal.MetalAwk.init(allocator) catch return null;
    defer searcher.deinit();

    var times = try allocator.alloc(u64, iterations);
    var last_matches: u64 = 0;

    for (0..iterations) |i| {
        var timer = try std.time.Timer.start();
        var result = searcher.processAwkRegex(text, pattern, options, allocator) catch {
            allocator.free(times);
            return null;
        };
        times[i] = timer.read() / std.time.ns_per_ms;
        last_matches = result.matches.len;
        result.deinit();
    }

    return BenchmarkResult{ .times = times, .matches = last_matches };
}

fn benchmarkVulkanRegex(text: []const u8, pattern: []const u8, options: AwkOptions, allocator: std.mem.Allocator, iterations: usize) !?BenchmarkResult {
    var searcher = gpu.vulkan.VulkanAwk.init(allocator) catch return null;
    defer searcher.deinit();

    var times = try allocator.alloc(u64, iterations);
    var last_matches: u64 = 0;

    for (0..iterations) |i| {
        var timer = try std.time.Timer.start();
        var result = searcher.processAwkRegex(text, pattern, options, allocator) catch {
            allocator.free(times);
            return null;
        };
        times[i] = timer.read() / std.time.ns_per_ms;
        last_matches = result.matches.len;
        result.deinit();
    }

    return BenchmarkResult{ .times = times, .matches = last_matches };
}

pub fn runRegexBenchmarks(allocator: std.mem.Allocator, file_size: usize, iterations: usize) !void {
    std.debug.print("\n====== REGEX BENCHMARK ======\n\n", .{});

    // Generate test data with numbers and mixed content
    const text = try generateRegexTestData(allocator, file_size);
    defer allocator.free(text);

    // Test patterns
    const patterns = [_][]const u8{
        "[0-9]+",
        "hel+o",
        "[a-z]+@[a-z]+",
        "error|warning",
    };

    const pattern_names = [_][]const u8{
        "numbers [0-9]+",
        "literal+ hel+o",
        "email-like",
        "alternation",
    };

    const options = AwkOptions{};

    for (patterns, 0..) |pattern, idx| {
        std.debug.print("\nPattern: {s}\n", .{pattern_names[idx]});
        std.debug.print("{s:<12} {s:>12} {s:>12} {s:>10}\n", .{ "Backend", "Avg (ms)", "Min (ms)", "Matches" });
        std.debug.print("{s:<12} {s:>12} {s:>12} {s:>10}\n", .{ "------------", "------------", "------------", "----------" });

        // CPU Regex
        var cpu_warmup = try cpu.processAwkRegex(text, pattern, options, allocator);
        const expected_matches = cpu_warmup.matches.len;
        cpu_warmup.deinit();

        const cpu_times = try benchmarkCpuRegex(text, pattern, options, allocator, iterations);
        defer allocator.free(cpu_times);

        const cpu_avg = average(cpu_times);
        const cpu_min = minimum(cpu_times);
        std.debug.print("{s:<12} {d:>12.1} {d:>12.1} {d:>10}\n", .{ "CPU-Regex", cpu_avg, cpu_min, expected_matches });

        // Metal Regex (macOS only)
        if (build_options.is_macos) {
            const metal_result = benchmarkMetalRegex(text, pattern, options, allocator, iterations) catch null;
            if (metal_result) |result| {
                defer allocator.free(result.times);
                const metal_avg = average(result.times);
                const metal_min = minimum(result.times);
                const speedup = cpu_avg / metal_avg;
                std.debug.print("{s:<12} {d:>12.1} {d:>12.1} {d:>10} ({d:.1}x)\n", .{ "Metal-Regex", metal_avg, metal_min, result.matches, speedup });
            } else {
                std.debug.print("{s:<12} {s:>12}\n", .{ "Metal-Regex", "unavailable" });
            }
        }

        // Vulkan Regex
        const vulkan_result = benchmarkVulkanRegex(text, pattern, options, allocator, iterations) catch null;
        if (vulkan_result) |result| {
            defer allocator.free(result.times);
            const vulkan_avg = average(result.times);
            const vulkan_min = minimum(result.times);
            const speedup = cpu_avg / vulkan_avg;
            std.debug.print("{s:<12} {d:>12.1} {d:>12.1} {d:>10} ({d:.1}x)\n", .{ "Vulkan-Regex", vulkan_avg, vulkan_min, result.matches, speedup });
        } else {
            std.debug.print("{s:<12} {s:>12}\n", .{ "Vulkan-Regex", "unavailable" });
        }
    }
}

fn generateRegexTestData(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const templates = [_][]const u8{
        "hello world code 123 process",
        "error: failed with code 456",
        "warning: possible issue at line 789",
        "user@example test email hello",
        "info: processing heello item 42",
        "debug: value=999 status=ok",
        "the quick brown fox 12345",
        "system helllo alert warning 0",
    };

    var data = try allocator.alloc(u8, size);
    var pos: usize = 0;
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    while (pos < size) {
        const template = templates[rng.intRangeAtMost(usize, 0, templates.len - 1)];
        const copy_len = @min(template.len, size - pos);
        @memcpy(data[pos..][0..copy_len], template[0..copy_len]);
        pos += copy_len;
        if (pos < size) {
            data[pos] = '\n';
            pos += 1;
        }
    }

    return data;
}
