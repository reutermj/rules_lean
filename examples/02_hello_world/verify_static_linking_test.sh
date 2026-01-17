#!/bin/bash
# Test: Verify lean_binary produces statically-linked executables
#
# Requirement: Lean binaries should only depend on basic system libraries,
# not on Lean-specific shared libraries or libc++.
#
# Approach: Run ldd on the test binary and verify:
#   1. No libc++.so dependency (we link Lean's static libc++)
#   2. No libgmp.so dependency (we link Lean's static libgmp)
#   3. No libuv.so dependency (we link Lean's static libuv)
#   4. No Lean-specific .so files
#
# Why this matters: Static linking ensures binaries are portable and don't
# require users to install Lean runtime libraries.

set -euo pipefail

BINARY="$1"

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: Binary not found or not executable: $BINARY"
    exit 1
fi

echo "Checking dynamic dependencies of: $BINARY"
LDD_OUTPUT=$(ldd "$BINARY" 2>&1)
echo "$LDD_OUTPUT"
echo ""

# Check for forbidden dependencies
FORBIDDEN_PATTERNS=(
    "libc\\+\\+\\.so"   # Should use static libc++ from Lean
    "libgmp\\.so"       # Should use static libgmp from Lean
    "libuv\\.so"        # Should use static libuv from Lean
    "liblean"           # No Lean shared libraries
    "libLean"           # No Lean shared libraries
)

FAILED=0
for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    if echo "$LDD_OUTPUT" | grep -qE "$pattern"; then
        echo "ERROR: Found forbidden dependency matching: $pattern"
        FAILED=1
    fi
done

# Verify expected system libraries are present
EXPECTED_PATTERNS=(
    "libc\\.so"         # Standard C library
    "libm\\.so"         # Math library
)

for pattern in "${EXPECTED_PATTERNS[@]}"; do
    if ! echo "$LDD_OUTPUT" | grep -qE "$pattern"; then
        echo "WARNING: Expected dependency not found: $pattern"
    fi
done

if [[ $FAILED -eq 1 ]]; then
    echo ""
    echo "FAILED: Binary has unexpected dynamic dependencies"
    exit 1
fi

echo ""
echo "PASSED: Binary has minimal dynamic dependencies (static linking verified)"
