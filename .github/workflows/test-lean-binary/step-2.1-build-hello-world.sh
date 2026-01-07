#!/bin/bash
set -euo pipefail

cd examples/02_hello_world

# Test: Build succeeds
echo "Building hello world binary..."
../../bazel build //:hello

# Test: Run succeeds and produces expected output
echo "Running hello world binary..."
OUTPUT=$(../../bazel run //:hello 2>&1)
if [[ "$OUTPUT" != *"Hello, World!"* ]]; then
    echo "ERROR: Expected output to contain 'Hello, World!'"
    echo "Actual output: $OUTPUT"
    exit 1
fi

echo "✓ Hello world binary builds and runs correctly"
