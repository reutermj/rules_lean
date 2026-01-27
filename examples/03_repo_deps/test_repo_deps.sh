#!/bin/bash
# Test script for lean_deps repository rule proof of concept

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Testing lean_deps repository rule ==="
echo ""

echo "1. Building show_deps target to display parsed dependency information..."
bazel build //:show_deps 2>&1

echo ""
echo "2. Contents of generated deps_info.txt:"
echo "----------------------------------------"
cat bazel-bin/deps_info.txt
echo "----------------------------------------"

echo ""
echo "3. Examining the generated repository files..."
echo ""
echo "Generated deps.bzl:"
echo "----------------------------------------"
cat "$(bazel info output_base)/external/my_lean_deps/deps.bzl"
echo "----------------------------------------"

echo ""
echo "Generated BUILD.bazel:"
echo "----------------------------------------"
cat "$(bazel info output_base)/external/my_lean_deps/BUILD.bazel"
echo "----------------------------------------"

echo ""
echo "=== Test completed successfully ==="
echo ""
echo "The dependency graph shows:"
echo "  - Utils.Math and Utils.String have no internal dependencies"
echo "  - Core.Types depends on Utils.Math"
echo "  - Core.Logic depends on Utils.Math and Utils.String"
echo "  - Main depends on Core.Types and Core.Logic"
echo ""
echo "Compilation order should be:"
echo "  Utils.Math -> Utils.String -> Core.Logic -> Core.Types -> Main"
echo "  (or similar valid topological ordering)"
