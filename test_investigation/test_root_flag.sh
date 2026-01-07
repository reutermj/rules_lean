#!/bin/bash
# Test script to compare current vs experimental --root flag approaches
#
# This script tests both the current implementation (file copying) and the
# experimental implementation (workspace root) to compare error message output.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "=========================================="
echo "Testing --root Flag Approaches"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Test 1: Current Implementation (File Copying)"
echo "----------------------------------------------"
echo "Expected: Error message shows bazel-out/... path"
echo ""

# Build with current implementation
if ./bazel build //test_investigation:error_test 2>&1 | tee /tmp/current_output.txt; then
    echo -e "${RED}✗ Build succeeded but should have failed (type error expected)${NC}"
    exit 1
else
    echo -e "${GREEN}✓ Build failed as expected (type error)${NC}"
    echo ""
    echo "Error output:"
    grep -A 3 "error:" /tmp/current_output.txt || echo "(no error found in output)"

    # Check if error path contains bazel-out
    if grep "bazel-out" /tmp/current_output.txt | grep "ErrorTest.lean" > /dev/null; then
        echo -e "${YELLOW}✓ Error path contains 'bazel-out' (current behavior)${NC}"
        CURRENT_PATH=$(grep -o "bazel-out[^:]*ErrorTest.lean" /tmp/current_output.txt | head -1)
        echo "   Path: $CURRENT_PATH"
    else
        echo -e "${RED}✗ Expected error path to contain 'bazel-out'${NC}"
    fi
fi

echo ""
echo "=========================================="
echo ""
echo "Test 2: Experimental Implementation (Workspace Root)"
echo "------------------------------------------------------"
echo "Expected: Error message shows clean 'test_investigation/ErrorTest.lean' path"
echo ""

# Backup current BUILD file and use experimental one
cp test_investigation/BUILD.bazel test_investigation/BUILD.bazel.backup
cp test_investigation/BUILD_experimental.bazel test_investigation/BUILD.bazel

# Build with experimental implementation
if ./bazel build //test_investigation:error_test 2>&1 | tee /tmp/experimental_output.txt; then
    echo -e "${RED}✗ Build succeeded but should have failed (type error expected)${NC}"
    # Restore BUILD file
    mv test_investigation/BUILD.bazel.backup test_investigation/BUILD.bazel
    exit 1
else
    echo -e "${GREEN}✓ Build failed as expected (type error)${NC}"
    echo ""
    echo "Error output:"
    grep -A 3 "error:" /tmp/experimental_output.txt || echo "(no error found in output)"

    # Check if error path is clean (no bazel-out)
    if grep "ErrorTest.lean" /tmp/experimental_output.txt | grep -v "bazel-out" > /dev/null; then
        echo -e "${GREEN}✓ Error path is clean (no 'bazel-out')${NC}"
        EXPERIMENTAL_PATH=$(grep -o "[^:]*ErrorTest.lean" /tmp/experimental_output.txt | grep -v bazel-out | head -1)
        echo "   Path: $EXPERIMENTAL_PATH"
    else
        echo -e "${RED}✗ Expected clean error path without 'bazel-out'${NC}"
    fi

    # Check debug output to verify workspace root detection
    echo ""
    echo "Debug output (workspace root detection):"
    grep "Workspace root:" /tmp/experimental_output.txt || echo "(debug output not found)"
fi

# Restore BUILD file
mv test_investigation/BUILD.bazel.backup test_investigation/BUILD.bazel

echo ""
echo "=========================================="
echo "Summary"
echo "=========================================="
echo ""
echo "Current approach (file copying):"
echo "  - Error path: Full bazel-out path"
echo "  - Example: bazel-out/k8-fastbuild/bin/error_test_lean_src/test_investigation/ErrorTest.lean:4:21"
echo "  - Hermetic: ✓"
echo "  - Remote execution: ✓"
echo "  - Clean errors: ✗"
echo ""
echo "Experimental approach (workspace root):"
echo "  - Error path: Workspace-relative path"
echo "  - Example: test_investigation/ErrorTest.lean:4:21"
echo "  - Hermetic: ✗"
echo "  - Remote execution: ✗"
echo "  - Clean errors: ✓"
echo ""
echo "See docs/issues/root-flag-investigation.md for detailed analysis and recommendations."
