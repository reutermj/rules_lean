# Error messages show bazel-out paths instead of source paths

## Problem

When Lean compilation fails, error messages reference the copied file in `bazel-out/` rather than the original source file:

```
bazel-out/k8-fastbuild/bin/error_test_lean_src/ErrorTest.lean:5:20: error: failed to synthesize
  OfNat String 42
```

Users would expect to see:
```
ErrorTest.lean:5:20: error: failed to synthesize
  OfNat String 42
```

## Cause

The `_lean_compile` function copies source files to preserve workspace-relative paths for correct module naming. Lean reports errors using the path it was given (the copy), not the original source.

## Impact

- IDE "click to jump to error" features won't work correctly
- Users may be confused about which file to edit
- Error messages are harder to read due to long paths

## Potential Solutions

1. **Post-process error output**: Use `sed` to rewrite paths in stderr
2. **Lean flag**: Check if Lean has a flag to control error path reporting
3. **Symlink approach**: Investigate if there's a way to make symlinks work with Lean's path validation

## Related

This is a consequence of the symlink workaround documented in `lean/private/rules.bzl`.
