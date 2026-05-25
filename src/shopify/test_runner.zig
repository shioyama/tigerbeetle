//! Custom test runner for the Shopify fork. Runs in simple mode (no IPC with
//! the build system), so we control all output formatting end-to-end:
//!
//! - No `error: '<test name>' failed: <stderr>` gluing from the build system.
//! - No stack-trace dump on failure (the test's own `std.debug.print` errors
//!   already describe the problem).
//! - Default output is one dot per passing test; failures break out with the
//!   test name and error name on their own line.
//! - `VERBOSE=1` switches to one `{name}... RESULT` line per test, useful when
//!   a slow test hangs and you want to see which one.
//! - Pass/fail/skip markers and the failure summary are colorized when stderr
//!   is a terminal (via `std.io.tty.detectConfig`). Force with `COLOR=1` /
//!   `COLOR=0` to override.
//!
//! Wired in via `build.zig` on `unit_tests` with `.mode = .simple`. Filter
//! selection (`./zig/zig build test -- <filter>`) still works because Zig
//! bakes the filter into `builtin.test_functions` at compile time.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const shopify_stdx = @import("stdx.zig");

// Honor `std.testing.log_level` at runtime so per-test silencers like
// `superblock_quorums_fuzz`'s `testing.log_level = .err; defer ... = level;`
// actually take effect — the default Zig logFn ignores `testing.log_level`,
// only `std_options.log_level` (which is comptime). Without this the suite
// dot row drowns under per-op vsr warnings during normal edge-case scenarios.
pub const std_options: std.Options = .{ .logFn = log };

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}

const Failure = struct { name: []const u8, err_name: []const u8 };

var tty_config: std.io.tty.Config = .no_color;

fn print(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print(fmt, args) catch {};
}

fn cprint(color: std.io.tty.Color, comptime fmt: []const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    tty_config.setColor(stderr, color) catch {};
    stderr.print(fmt, args) catch {};
    tty_config.setColor(stderr, .reset) catch {};
}

pub fn main() void {
    const verbose = shopify_stdx.truthy(std.posix.getenv("VERBOSE"));
    tty_config = if (std.posix.getenv("COLOR")) |v|
        if (shopify_stdx.truthy(v)) .escape_codes else .no_color
    else
        std.io.tty.detectConfig(std.io.getStdErr());

    // Each `b.addTest` produces a separate binary (`test-unit`, `test-stdx`,
    // `test-integration`, `test-tb-snapshot`); they run in sequence under
    // `zig build test`. Print the binary name as a header so the split between
    // suites is visible in the combined output.
    const suite = if (std.os.argv.len > 0)
        std.fs.path.basename(std.mem.sliceTo(std.os.argv[0], 0))
    else
        "test";
    cprint(.bold, "=== {s} ===", .{suite});
    print("\n", .{});

    const test_fn_list = builtin.test_functions;
    var passed: u32 = 0;
    var skipped: u32 = 0;
    var leaked: u32 = 0;

    var failures: std.ArrayListUnmanaged(Failure) = .{};
    defer failures.deinit(std.heap.page_allocator);

    for (test_fn_list) |test_fn| {
        testing.allocator_instance = .{};
        const result = test_fn.func();
        const leaked_this = testing.allocator_instance.deinit() == .leak;
        if (leaked_this) leaked += 1;

        if (result) |_| {
            // A leak supersedes a clean pass — skip the PASS marker so the
            // summary counts add up (the LEAK marker below names the test).
            if (!leaked_this) {
                passed += 1;
                if (verbose) {
                    print("{s}... ", .{test_fn.name});
                    cprint(.green, "PASS", .{});
                    print("\n", .{});
                } else {
                    cprint(.green, ".", .{});
                }
            }
        } else |err| switch (err) {
            error.SkipZigTest => {
                skipped += 1;
                if (verbose) {
                    print("{s}... ", .{test_fn.name});
                    cprint(.yellow, "SKIP", .{});
                    print("\n", .{});
                } else {
                    cprint(.yellow, "S", .{});
                }
            },
            else => {
                // The test's own `std.debug.print` output (its error context)
                // lands above this line. A leading `\n` keeps the FAIL line
                // clear of the dot row in default mode.
                const err_name = @errorName(err);
                print("\n{s}... ", .{test_fn.name});
                cprint(.red, "FAIL ({s})", .{err_name});
                print("\n", .{});
                failures.append(std.heap.page_allocator, .{
                    .name = test_fn.name,
                    .err_name = err_name,
                }) catch @panic("OOM");
            },
        }

        if (leaked_this) {
            print("\n{s}... ", .{test_fn.name});
            cprint(.red, "LEAK", .{});
            print("\n", .{});
        }
    }

    if (!verbose) print("\n", .{});

    if (failures.items.len > 0) {
        print("\n", .{});
        cprint(.red, "Failed tests:", .{});
        print("\n", .{});
        for (failures.items) |f| {
            print("  - {s} (", .{f.name});
            cprint(.red, "{s}", .{f.err_name});
            print(")\n", .{});
        }
        print("\n", .{});
    }

    const failed = failures.items.len;
    print("{d} passed, {d} skipped, ", .{ passed, skipped });
    if (failed > 0) {
        cprint(.red, "{d} failed", .{failed});
    } else {
        print("{d} failed", .{failed});
    }
    if (leaked != 0) {
        print(", ", .{});
        cprint(.red, "{d} leaked", .{leaked});
    }
    // Trailing blank line so the next suite's `=== <name> ===` header has
    // visual breathing room when binaries run back-to-back under `zig build test`.
    print("\n\n", .{});

    if (failures.items.len > 0 or leaked > 0) std.process.exit(1);
}
