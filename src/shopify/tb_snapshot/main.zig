const std = @import("std");
const stdx = @import("stdx");
const vsr = @import("vsr");
const constants = vsr.constants;

const rewrite = @import("rewrite.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

const CLIArgs = struct {
    replica: u8,
    replica_count: u8,
    development: bool = false,
    clear_wal: bool = false,
    sync_ops: bool = false,
    drain_pipeline: bool = false,
    addresses: ?[]const u8 = null,
    @"--": void,
    path: []const u8,

    pub const help =
        \\Usage: tb-snapshot [options] <path>
        \\
        \\Prepare a TigerBeetle data file snapshot for use as a new cluster
        \\or to seed a replica in an existing cluster.
        \\
        \\Options:
        \\  --replica=N           Target replica index (required)
        \\  --replica-count=N     Number of replicas (required)
        \\  --development         Allow without direct I/O
        \\  --clear-wal           Zero the WAL (for seeding into existing cluster)
        \\  --sync-ops            Set sync range for cluster repair
        \\  --drain-pipeline      Connect to cluster to drain prepare pipeline (NACK safety)
        \\  --addresses=ADDRS     Cluster addresses (required with --drain-pipeline)
        \\  -h, --help            Show this help
        \\  --version             Show version and exit
        \\
        \\Examples:
        \\  New cluster from snapshot:
        \\    tb-snapshot --replica=0 --replica-count=1 snapshot.tigerbeetle
        \\
        \\  Seed replica into existing cluster:
        \\    tb-snapshot --replica=1 --replica-count=6 \
        \\        --clear-wal --sync-ops \
        \\        --drain-pipeline --addresses=addr1,addr2,... \
        \\        snapshot.tigerbeetle
        \\
    ;
};

pub fn main() !void {
    var gpa_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa_instance.deinit();

    const gpa = gpa_instance.allocator();

    try maybe_print_help_or_version(gpa);

    var arg_iterator = try std.process.argsWithAllocator(gpa);
    defer arg_iterator.deinit();

    const cli = stdx.flags(&arg_iterator, CLIArgs);

    if (cli.drain_pipeline and cli.addresses == null) {
        vsr.fatal(.cli, "--drain-pipeline requires --addresses", .{});
    }
    if (cli.addresses != null and !cli.drain_pipeline) {
        vsr.fatal(.cli, "--addresses requires --drain-pipeline", .{});
    }

    var address_buf: [constants.members_max]std.net.Address = undefined;
    const addresses: ?[]const std.net.Address = if (cli.addresses) |raw|
        vsr.parse_addresses(raw, &address_buf) catch {
            vsr.fatal(.cli, "invalid --addresses", .{});
        }
    else
        null;

    try rewrite.run(gpa, .{
        .replica = cli.replica,
        .replica_count = cli.replica_count,
        .development = cli.development,
        .clear_wal = cli.clear_wal,
        .sync_ops = cli.sync_ops,
        .drain_pipeline = cli.drain_pipeline,
        .addresses = addresses,
        .path = cli.path,
    });
}

// Other TB binaries (tigerbeetle, aof, scripts) shape their CLI as a `union(enum)` of
// subcommands, which `stdx.flags` auto-handles `-h/--help` for. tb-snapshot has only one
// operation, and `stdx.flags.parse_commands` asserts `len >= 2`, so a single-subcommand
// union isn't expressible. We use a flat struct and scan for `--help`/`--version` ourselves.
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
