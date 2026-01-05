#!/bin/bash
# Test that toolchain registration doesn't error
set -euo pipefail

cd examples/01_toolchain

# Verify toolchain registers without error
../../bazel query @lean_toolchain_linux_x86_64//...
