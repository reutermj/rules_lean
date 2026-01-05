#!/bin/bash
# Validate expected toolchain targets exist
set -euo pipefail

cd examples/01_toolchain

# Validate expected targets exist
../../bazel query @lean_toolchain_linux_x86_64//... | grep -q "toolchain"
