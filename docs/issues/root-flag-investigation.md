# Investigation: Using --root Flag to Fix Error Path Reporting

## Summary

**Question**: Can we point Lean's `--root` flag at the source directory instead of the copied location to resolve error path reporting issues?

**Answer**: Yes, with caveats. This approach can work but has trade-offs regarding hermiticity and remote execution compatibility.

## Current Behavior

### Problem
Error messages show `bazel-out` paths instead of workspace-relative paths:
```
bazel-out/k8-fastbuild/bin/error_test_lean_src/ErrorTest.lean:5:20: error: ...
```

Expected:
```
ErrorTest.lean:5:20: error: ...
```

### Root Cause
The current implementation (in `lean/private/rules.bzl:38-82`):

1. **Copies** source files to `bazel-out/.../target_lean_src/path/to/File.lean`
2. Sets `--root=bazel-out/.../target_lean_src`
3. Lean compiles the copy and reports errors using that path

Files are copied because Lean enforces: `realpath(source_file)` must start with `realpath(--root)`

With Bazel's symlink-based execroot:
- `realpath(execroot/path/to/File.lean)` → `/home/user/workspace/path/to/File.lean` (follows symlink)
- `realpath(execroot)` → `/tmp/.../sandbox/.../execroot/_main/` (sandbox path)
- These don't match, so Lean validation fails

## Proposed Solution

### Approach: Point --root at the actual workspace directory

Instead of copying files and using the copy location as --root, we can:

1. Determine the **actual workspace root** (e.g., `/home/user/workspace`)
2. Set `--root` to the actual workspace root
3. Pass the symlinked source file (which resolves to the actual location)
4. Lean's validation passes because `realpath(file)` starts with `realpath(--root)`
5. Errors are reported relative to the workspace root

### Implementation

In `lean/private/rules.bzl`, the `_lean_compile` function would change from:

```python
# Current: Copy files and use copy location as root
src_copy = ctx.actions.declare_file(ctx.label.name + "_lean_src/" + src.short_path)
root_dir = src_copy.path[:-(len(src.short_path) + 1)]
```

To:

```python
# Proposed: Derive workspace root and use it directly
# The symlink src.path resolves to the actual source location
# By removing the short_path suffix, we get the workspace root
command = """
WORKSPACE_ROOT=$(readlink -f {src} | sed 's|/{short_path}$||')
{lean} --root=$WORKSPACE_ROOT {src} -c {out}
""".format(
    src = src.path,
    short_path = src.short_path,
    lean = lean.path,
    out = c_file.path,
)
```

### How It Works

1. `readlink -f {src}` resolves the symlink to its real path: `/home/user/workspace/path/to/File.lean`
2. `sed 's|/{short_path}$||'` removes the file path to get workspace root: `/home/user/workspace`
3. `--root=$WORKSPACE_ROOT` points Lean at the actual workspace
4. Lean compiles using the real file (via symlink)
5. Errors show workspace-relative paths: `path/to/File.lean:line:col`

### Validation

Lean's path validation:
- `realpath(--root)` = `/home/user/workspace`
- `realpath(path/to/File.lean)` = `/home/user/workspace/path/to/File.lean` (follows symlink)
- Validation passes: ✓ file path starts with root path

## Trade-offs Analysis

### Advantages ✅

1. **Fixes error path reporting**: Errors show `path/to/File.lean` instead of `bazel-out/.../path/to/File.lean`
2. **IDE integration works**: Click-to-error will jump to the correct source file
3. **Cleaner output**: Error messages are more readable
4. **No file copying**: Eliminates the overhead of copying source files
5. **Faster builds**: No copy action means faster analysis and execution

### Disadvantages ❌

1. **Breaks hermiticity**: Build depends on absolute workspace path
   - Build outputs may vary if workspace is at different paths
   - Not ideal for reproducible builds

2. **Remote execution incompatible**:
   - Remote executors don't have access to local workspace
   - Would need workarounds or fallback to file copying

3. **Sandbox mode issues**:
   - Strict sandboxing may prevent access to files outside sandbox
   - May require `--strategy=LeanCompile=local` or similar

4. **External dependencies**:
   - Source files from external repositories might not be accessible
   - Would need special handling for `@external_repo//...` targets

## Recommendations

### Option 1: Hybrid Approach (Recommended)

Add a configuration option to choose between approaches:

```python
# MODULE.bazel
lean.toolchain(
    version = "4.12.0",
    use_workspace_root = True,  # Enable better error paths (local development)
)
```

- **Default (False)**: Use file copying (hermetic, works with remote execution)
- **Opt-in (True)**: Use workspace root (better error paths for local development)

This provides:
- Hermetic builds for CI/remote execution (default)
- Better error messages for local development (opt-in)

### Option 2: Post-process stderr (Alternative)

Keep current approach but rewrite paths in error output:

```python
command = """
{lean} --root={root} {src_copy} -c {out} 2>&1 | \\
    sed 's|{root}/|./|g' >&2
""".format(...)
```

Advantages:
- Maintains hermiticity
- Works with remote execution
- Fixes error path display

Disadvantages:
- IDE integration still broken (paths in binary metadata aren't rewritten)
- Hacky solution that might break with Lean updates

### Option 3: Check for Lean Flag (Best if available)

Investigate if Lean has a flag to control error path reporting:
- Something like `--error-format=relative` or `--source-root=...`
- Would be the cleanest solution if available
- Need to check Lean documentation/source code

## Next Steps

1. **Test the workspace root approach**:
   - Create a branch with the modified implementation
   - Test with local builds to verify error messages
   - Test edge cases (external deps, nested packages)

2. **Check Lean documentation**:
   - Look for existing flags that control error path formatting
   - Check Lean GitHub issues for related discussions

3. **Implement hybrid approach**:
   - Add `use_workspace_root` configuration option
   - Update documentation with trade-offs
   - Add tests for both modes

4. **Consider submitting Lean feature request**:
   - If no existing flag exists, propose a `--error-source-root` flag
   - This would allow hermetic builds with clean error messages

## Test Plan

To verify the workspace root approach works:

```bash
# 1. Create test file with error
cat > test/ErrorTest.lean <<EOF
def main : IO Unit := do
  let x : String := 42  -- Type error
  IO.println "test"
EOF

# 2. Modify rules.bzl to use workspace root approach
# (see Implementation section above)

# 3. Build and capture error output
bazel build //test:error_test 2>&1 | tee error_output.txt

# 4. Verify error shows clean path
# Expected: "ErrorTest.lean:2:21: error: type mismatch"
# NOT: "bazel-out/.../test_lean_src/test/ErrorTest.lean:2:21: error: ..."
grep "ErrorTest.lean:2:21" error_output.txt && echo "✓ Clean error paths work!"
```

## References

- Issue documentation: `docs/issues/error-path-mapping.md`
- Current implementation: `lean/private/rules.bzl:38-82`
- Lean path validation: Explained in `lean/private/rules.bzl:3-37`
