#!/usr/bin/env bash
# Generate a fresh u64 fingerprint for build.zig.zon.
#
# Usage:
#   bash scripts/gen-fingerprint.sh
#   bash scripts/gen-fingerprint.sh | xclip   # copy to clipboard
#
# Outputs a string like: 0x9a3c1f8b7e2d4a01

set -euo pipefail

if command -v openssl >/dev/null 2>&1; then
    hex=$(openssl rand -hex 8)
elif [ -r /dev/urandom ]; then
    hex=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
else
    echo "error: no random source available (need openssl or /dev/urandom)" >&2
    exit 1
fi

echo "0x${hex}"
