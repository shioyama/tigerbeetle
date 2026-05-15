//! Fork-specific GitHub helpers.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;

const Shell = @import("../shell.zig");
const stdx = @import("./stdx.zig");

/// Open the GitHub compare page for `branch` against `main`, pre-filled with
/// `title` and `body`. The author reviews/edits in the browser and clicks
/// "Create pull request" themselves — so the script never opens an unintended PR.
pub fn open_pr_compare(
    shell: *Shell,
    allocator: std.mem.Allocator,
    branch: []const u8,
    title: []const u8,
    body: []const u8,
) !void {
    var url_buf = std.ArrayList(u8).init(allocator);
    const url_writer = url_buf.writer();
    try url_writer.writeAll("https://github.com/shop/tigerbeetle/compare/main...");
    try stdx.query_percent_encode(url_writer, branch);
    try url_writer.writeAll("?expand=1&title=");
    try stdx.query_percent_encode(url_writer, title);
    if (body.len > 0) {
        try url_writer.writeAll("&body=");
        try stdx.query_percent_encode(url_writer, body);
    }
    const url = url_buf.items;

    log.info("opening PR: {s}", .{url});

    switch (builtin.os.tag) {
        .macos => try shell.exec("open {url}", .{ .url = url }),
        .linux => try shell.exec("xdg-open {url}", .{ .url = url }),
        else => {
            const stdout = std.io.getStdOut().writer();
            try stdout.print("Open this URL to create the PR:\n{s}\n", .{url});
        },
    }
}
