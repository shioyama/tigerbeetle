//! Registers fork-only Zig modules onto the tigerbeetle binary's root module.
//!
//! Files under `src/shopify/` are outside `src/tigerbeetle/`'s module path, so
//! a relative-path import of one of them from the binary's root file fails
//! Zig's module-boundary check. Wiring them as named modules here lets callers
//! reach them by name, and keeps the upstream-touched lines in `build.zig` to
//! a single helper invocation per build entry point.
//!
//! Modules registered (the literal `@import` strings here also satisfy the
//! byte-level dead-file detector in `src/tidy.zig`, which can't see files
//! reached via named-module imports):
//! - `@import("./shadow.zig")` exposed as `shopify_shadow`

const std = @import("std");

pub fn add_to_tigerbeetle(
    b: *std.Build,
    root_module: *std.Build.Module,
    vsr_module: *std.Build.Module,
) void {
    const shadow = b.createModule(.{
        .root_source_file = b.path("src/shopify/shadow.zig"),
    });
    shadow.addImport("vsr", vsr_module);
    root_module.addImport("shopify_shadow", shadow);
}
