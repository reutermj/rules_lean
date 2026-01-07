#!/bin/bash
set -euo pipefail

cd examples/02_hello_world

# Test 1: Nested source files referenced from workspace root
# BUILD at //, source at subdir/inner/Nested.lean → module "subdir.inner.Nested"
echo "Testing module naming: BUILD at root, source in subdirectory..."
../../bazel build //:nested_module_test

OUTPUT=$(../../bazel run //:nested_module_test 2>&1)
if [[ "$OUTPUT" != *"Nested module works!"* ]]; then
    echo "ERROR: Expected output to contain 'Nested module works!'"
    echo "Actual output: $OUTPUT"
    exit 1
fi

# Verify the path structure in the action
ACTION_OUTPUT=$(../../bazel aquery //:nested_module_test --output=text 2>&1)
if [[ "$ACTION_OUTPUT" != *"nested_module_test_lean_src/subdir/inner/Nested.lean"* ]]; then
    echo "ERROR: Source copy path doesn't preserve workspace-relative structure"
    echo "Expected path to contain: nested_module_test_lean_src/subdir/inner/Nested.lean"
    exit 1
fi

echo "✓ Module naming correct for BUILD at root with nested source"

# Test 2: BUILD file colocated with source file
# BUILD at //nested/deep/, source at nested/deep/App.lean → module "nested.deep.App"
# This ensures module name is workspace-relative, not BUILD-file-relative
echo "Testing module naming: BUILD colocated with source..."
../../bazel build //nested/deep:colocated_module_test

OUTPUT=$(../../bazel run //nested/deep:colocated_module_test 2>&1)
if [[ "$OUTPUT" != *"Module naming works!"* ]]; then
    echo "ERROR: Expected output to contain 'Module naming works!'"
    echo "Actual output: $OUTPUT"
    exit 1
fi

# Verify the path structure - should still be workspace-relative
ACTION_OUTPUT=$(../../bazel aquery //nested/deep:colocated_module_test --output=text 2>&1)
if [[ "$ACTION_OUTPUT" != *"colocated_module_test_lean_src/nested/deep/App.lean"* ]]; then
    echo "ERROR: Colocated BUILD: source copy path doesn't preserve workspace-relative structure"
    echo "Expected path to contain: colocated_module_test_lean_src/nested/deep/App.lean"
    exit 1
fi

echo "✓ Module naming correct for colocated BUILD with source"

echo ""
echo "✓ All module naming tests passed"
