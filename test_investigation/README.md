# --root Flag Investigation Test Files

This directory contains test files for investigating the use of Lean's `--root` flag to fix error path reporting.

## Files

- **ErrorTest.lean**: Test file with a deliberate type error for demonstrating error path reporting
- **BUILD.bazel**: Standard build file using the current implementation (file copying)
- **BUILD_experimental.bazel**: Build file using the experimental workspace root approach
- **test_root_flag.sh**: Test script that compares both approaches

## Quick Start

To test both approaches and compare error messages:

```bash
./test_investigation/test_root_flag.sh
```

This will:
1. Build with the current implementation and capture error output
2. Build with the experimental implementation and capture error output
3. Compare the error paths shown in each approach

## Manual Testing

### Test Current Approach

```bash
./bazel build //test_investigation:error_test 2>&1 | tee current_output.txt
```

Expected error path: `bazel-out/k8-fastbuild/bin/error_test_lean_src/test_investigation/ErrorTest.lean:4:21`

### Test Experimental Approach

```bash
# Use experimental BUILD file
cp test_investigation/BUILD_experimental.bazel test_investigation/BUILD.bazel

# Build and observe error output
./bazel build //test_investigation:error_test 2>&1 | tee experimental_output.txt

# Restore original BUILD file
git restore test_investigation/BUILD.bazel
```

Expected error path: `test_investigation/ErrorTest.lean:4:21`

## Documentation

See [docs/issues/root-flag-investigation.md](../docs/issues/root-flag-investigation.md) for:
- Detailed analysis of the approach
- Trade-offs and recommendations
- Implementation details
- Next steps

## Related Files

- **lean/private/rules.bzl**: Current implementation (uses file copying)
- **lean/private/rules_experimental.bzl**: Experimental implementation (uses workspace root)
- **docs/issues/error-path-mapping.md**: Original issue documentation
