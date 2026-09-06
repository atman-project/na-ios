#!/bin/bash
#
# Build crrdb-mcp as a static library for iOS and copy the bindings + .a
# into crrdb-mcp/ so the Xcode project can link against it.
#
# Usage:
#   ./build_crrdb_mcp.sh --release        # release profile
#   ./build_crrdb_mcp.sh --arm64          # device only
#   ./build_crrdb_mcp.sh --sim-arm64      # Apple Silicon simulator only
#   ./build_crrdb_mcp.sh --x86_64        # Intel simulator only
#
# The installed crrdb-mcp/libcrrdb_mcp.a is always one slice — pick the one
# matching the destination you're about to build for in Xcode:
#   - simulator on Apple Silicon → run with --sim-arm64
#   - real iPhone / Archive      → run with --arm64

set -uexo pipefail

IOS_DIR="$(cd "$(dirname "$0")" && pwd)"
CRRDB_DIR="$(cd "$IOS_DIR/submodules/crrdb-mcp" && pwd)"

cd "$CRRDB_DIR"
bash ./build_bindings.sh "$@"

MODE="debug"
if [[ "$*" == *"--release"* ]]; then
  MODE="release"
fi

ARM64=false
SIM_ARM64=false
X86_64=false
if [[ "$*" == *"--arm64"* ]]; then ARM64=true; fi
if [[ "$*" == *"--sim-arm64"* ]]; then SIM_ARM64=true; fi
if [[ "$*" == *"--x86_64"* ]]; then X86_64=true; fi

if ! $ARM64 && ! $SIM_ARM64 && ! $X86_64; then
  echo "build_crrdb_mcp.sh: target must be specified: --arm64 / --sim-arm64 / --x86_64"
  exit 1
fi

mkdir -p $IOS_DIR/crrdb-mcp
rm -f $IOS_DIR/crrdb-mcp/libcrrdb_mcp.a $IOS_DIR/crrdb-mcp/crrdb_mcp.swift
rm -rf $IOS_DIR/crrdb-mcp/crrdb_mcpFFI

# Swift's include-path module discovery wants `module.modulemap` (not
# `crrdb_mcpFFI.modulemap`), inside a directory named like the module.
cp "$CRRDB_DIR/target/uniffi-bindings/swift/crrdb_mcp.swift" "$IOS_DIR/crrdb-mcp/crrdb_mcp.swift"
mkdir -p "$IOS_DIR/crrdb-mcp/crrdb_mcpFFI"
cp "$CRRDB_DIR/target/uniffi-bindings/swift/crrdb_mcpFFI.h" "$IOS_DIR/crrdb-mcp/crrdb_mcpFFI/crrdb_mcpFFI.h"
cp "$CRRDB_DIR/target/uniffi-bindings/swift/crrdb_mcpFFI.modulemap" "$IOS_DIR/crrdb-mcp/crrdb_mcpFFI/module.modulemap"

if $ARM64 && ! $SIM_ARM64 && ! $X86_64; then
  cp "$CRRDB_DIR/target/aarch64-apple-ios/$MODE/libcrrdb_mcp.a" "$IOS_DIR/crrdb-mcp/libcrrdb_mcp.a"
elif $SIM_ARM64 && ! $ARM64 && ! $X86_64; then
  cp "$CRRDB_DIR/target/aarch64-apple-ios-sim/$MODE/libcrrdb_mcp.a" "$IOS_DIR/crrdb-mcp/libcrrdb_mcp.a"
elif $X86_64 && ! $ARM64 && ! $SIM_ARM64; then
  cp "$CRRDB_DIR/target/x86_64-apple-ios/$MODE/libcrrdb_mcp.a" "$IOS_DIR/crrdb-mcp/libcrrdb_mcp.a"
else
  echo "build_crrdb_mcp.sh: multiple targets specified" >&2
  echo "Re-run with exactly one of --arm64 / --sim-arm64 / --x86_64" >&2
  exit 2
fi

ls -lh "$IOS_DIR/crrdb-mcp/libcrrdb_mcp.a" "$IOS_DIR/crrdb-mcp/crrdb_mcp.swift" \
  "$IOS_DIR/crrdb-mcp/crrdb_mcpFFI/crrdb_mcpFFI.h" "$IOS_DIR/crrdb-mcp/crrdb_mcpFFI/module.modulemap"
