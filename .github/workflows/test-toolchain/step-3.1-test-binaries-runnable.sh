#!/bin/bash
# Verify toolchain binaries are runnable
set -euo pipefail

cd examples/01_toolchain

# Test that lean binary runs and reports correct version
../../bazel run @lean_toolchain_linux_x86_64//:lean -- --version | grep -q "Lean (version 4.12.0"

# Test that leanc binary runs
../../bazel run @lean_toolchain_linux_x86_64//:leanc -- --version | grep -q "clang version"
