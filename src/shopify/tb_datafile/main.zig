const std = @import("std");
const stdx = @import("stdx");
const vsr = @import("vsr");
const constants = vsr.constants;

const identity = @import("identity.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

const CLIArgs = struct {
    cluster: ?u128 = null,
    replica: ?u8 = null,
    replica_count: ?u8 = null,
    flags: ?u64 = null,
    json: bool = false,
    quiet: bool = false,
    @"--": void,
    path: []const u8,

    pub const help =
        \\Usage: tb-datafile [options] <path>
        \\
        \\Inspect and optionally validate a TigerBeetle datafile's superblock identity.
        \\
        \\Options:
        \\  --cluster=N           Expected cluster id
        \\  --replica=N           Expected replica/member index
        \\  --replica-count=N     Expected replica count
        \\  --flags=N             Expected superblock flags (use --flags=0 for deploy checks)
        \\  --json                Print identity as JSON
        \\  --quiet               Suppress identity output on successful validation
        \\  -h, --help            Show this help
        \\  --version             Show version and exit
        \\
        \\Examples:
        \\  Inspect a datafile:
        \\    tb-datafile /data/tigerbeetle/123_0.tigerbeetle
        \\
        \\  Validate identity for Chef/systemd pre-start:
        \\    tb-datafile --quiet --cluster=123 --replica=0 --replica-count=6 \\
        \\        /data/tigerbeetle/123_0.tigerbeetle
        \\
    ;
};

pub fn main() !void {
    var gpa_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa_instance.deinit();

    const gpa = gpa_instance.allocator();

    try maybe_print_help_or_version(gpa);

    var flags = stdx.Flags.init(gpa);
    defer flags.deinit(gpa);

    const cli = flags.parse(CLIArgs);

    const datafile_identity = identity.read(cli.path) catch |err| {
        vsr.fatal(.cli, "failed to read datafile identity from '{s}': {s}", .{
            cli.path,
            @errorName(err),
        });
    };

    if (identity.validate(datafile_identity, .{
        .cluster = cli.cluster,
        .replica = cli.replica,
        .replica_count = cli.replica_count,
        .flags = cli.flags,
    })) |mismatch| {
        var stderr_buffer = std.io.bufferedWriter(std.io.getStdErr().writer());
        try identity.format_mismatch(stderr_buffer.writer(), mismatch);
        try stderr_buffer.flush();
        std.process.exit(1);
    }

    if (!cli.quiet) {
        var stdout_buffer = std.io.bufferedWriter(std.io.getStdOut().writer());
        const stdout = stdout_buffer.writer();
        if (cli.json) {
            try identity.print_json(stdout, datafile_identity);
        } else {
            try identity.print_human(stdout, datafile_identity);
        }
        try stdout_buffer.flush();
    }
}

// Other TB binaries (tigerbeetle, aof, scripts) shape their CLI as a `union(enum)` of
// subcommands, which `stdx.Flags.parse` auto-handles `-h/--help` for. tb-datafile has only
// one operation, and `parse_commands` asserts `len >= 2`, so a single-subcommand union
// isn't expressible. We use a flat struct and scan for `--help`/`--version` ourselves.
fn maybe_print_help_or_version(gpa: std.mem.Allocator) !void {
    var iter = try std.process.argsWithAllocator(gpa);
    defer iter.deinit();

    _ = iter.next(); // program name
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.io.getStdOut().writeAll(CLIArgs.help) catch std.process.exit(1);
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "--version")) {
            const stdout = std.io.getStdOut().writer();
            std.fmt.format(stdout, "TigerBeetle version {}\n", .{constants.semver}) catch
                std.process.exit(1);
            std.process.exit(0);
        }
    }
}
