#!/bin/bash
set -euo pipefail

cd examples/02_hello_world

# Test: Exit code propagation
# This validates the success criterion "Exit code is propagated correctly"
echo "Testing exit code propagation..."
../../bazel run //:exit_test && EXIT_CODE=$? || EXIT_CODE=$?
if [[ "$EXIT_CODE" != "42" ]]; then
    echo "ERROR: Expected exit code 42, got $EXIT_CODE"
    exit 1
fi

echo "✓ Exit codes propagate correctly"
