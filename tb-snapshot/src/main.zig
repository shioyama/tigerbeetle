const std = @import("std");
const log = std.log.scoped(.main);

const rewrite = @import("rewrite.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    var arg_iterator = try std.process.argsWithAllocator(gpa);
    defer arg_iterator.deinit();

    // Skip program name.
    _ = arg_iterator.next();

    const args = parseArgs(&arg_iterator) orelse {
        printUsage();
        std.process.exit(1);
    };

    try rewrite.run(gpa, args);
}

const Args = rewrite.Args;

fn parseArgs(arg_iterator: *std.process.ArgIterator) ?Args {
    var args = Args{};

    while (arg_iterator.next()) |arg| {
        if (parseFlag(arg, "--replica=")) |val| {
            args.replica = std.fmt.parseInt(u8, val, 10) catch return null;
        } else if (parseFlag(arg, "--replica-count=")) |val| {
            args.replica_count = std.fmt.parseInt(u8, val, 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--clear-wal")) {
            args.clear_wal = true;
        } else if (std.mem.eql(u8, arg, "--sync-ops")) {
            args.sync_ops = true;
        } else if (std.mem.eql(u8, arg, "--drain-pipeline") or
            std.mem.eql(u8, arg, "--flush-pipeline")) // deprecated alias
        {
            args.drain_pipeline = true;
        } else if (parseFlag(arg, "--addresses=")) |val| {
            args.addresses = val;
        } else if (std.mem.eql(u8, arg, "--development")) {
            args.development = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            args.path = arg;
        } else {
            log.err("unknown option: {s}", .{arg});
            return null;
        }
    }

    if (args.replica == null or args.replica_count == null or args.path == null) return null;

    if (args.drain_pipeline and args.addresses == null) {
        log.err("--drain-pipeline requires --addresses", .{});
        return null;
    }
    if (args.addresses != null and !args.drain_pipeline) {
        log.err("--addresses requires --drain-pipeline", .{});
        return null;
    }

    return args;
}

fn parseFlag(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, prefix)) {
        return arg[prefix.len..];
    }
    return null;
}

fn printUsage() void {
    const usage =
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
    std.io.getStdErr().writeAll(usage) catch {};
}
