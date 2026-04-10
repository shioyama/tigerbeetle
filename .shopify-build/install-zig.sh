#!/usr/bin/env sh
set -eu

if [ -f .zig-install/zig ]; then
    echo "Zig already installed, skipping download."
    exit 0
fi

sh -eux ./zig/download.sh
mkdir -p .zig-install
mv zig/zig zig/lib zig/doc zig/LICENSE zig/README.md .zig-install/
