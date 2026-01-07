"""Experimental implementation using workspace root for --root flag.

This file demonstrates the proposed solution for fixing error path reporting.
Instead of copying files and using the copy location as --root, this approach
points --root at the actual workspace directory.

WARNING: This is experimental and has trade-offs. See docs/issues/root-flag-investigation.md
"""

def _lean_compile_with_workspace_root(ctx, src, lean, c_file):
    """Compiles a .lean file using the workspace root as --root.

    This approach eliminates file copying and produces cleaner error messages
    by pointing --root at the actual workspace directory.

    Trade-offs:
    - ✅ Clean error paths (e.g., "proj/Foo.lean:5:20" instead of "bazel-out/.../proj/Foo.lean:5:20")
    - ✅ IDE click-to-error works correctly
    - ✅ No file copying overhead
    - ❌ Breaks hermiticity (depends on workspace absolute path)
    - ❌ Incompatible with remote execution
    - ❌ May not work in strict sandboxes

    How it works:
    1. The source file in execroot is a symlink to the actual source
    2. readlink -f resolves the symlink to get the real path: /path/to/workspace/proj/Foo.lean
    3. We extract the workspace root: /path/to/workspace
    4. Set --root to the workspace root
    5. Lean compiles using the real file (via symlink)
    6. Errors are reported relative to workspace root: proj/Foo.lean:5:20

    Lean's validation:
    - realpath(--root) = /path/to/workspace
    - realpath(src.path) = /path/to/workspace/proj/Foo.lean (follows symlink)
    - Validation passes: ✓ file path starts with root path

    Args:
        ctx: The rule context.
        src: The source .lean file (symlink in execroot).
        lean: The lean compiler executable.
        c_file: The output .c file to produce.
    """

    # Derive workspace root from the source file's real path
    # src.path points to a symlink in execroot
    # readlink -f resolves it to the actual source location
    # We remove the short_path to get the workspace root
    #
    # Example:
    #   src.path = "proj/Foo.lean" (symlink in execroot)
    #   readlink -f resolves to: /home/user/workspace/proj/Foo.lean
    #   src.short_path = "proj/Foo.lean"
    #   WORKSPACE_ROOT = /home/user/workspace

    ctx.actions.run_shell(
        mnemonic = "LeanCompile",
        command = """
set -euo pipefail

# Resolve the symlink to get the actual source file path
REAL_SRC=$(readlink -f {src})

# Extract workspace root by removing the short_path suffix
# This works because: real_path = workspace_root + "/" + short_path
WORKSPACE_ROOT=$(echo "$REAL_SRC" | sed 's|/{short_path}$||')

# Debug output (can be removed in production)
echo "Source symlink: {src}" >&2
echo "Real source: $REAL_SRC" >&2
echo "Short path: {short_path}" >&2
echo "Workspace root: $WORKSPACE_ROOT" >&2

# Compile with --root pointing to workspace root
# Lean will:
# 1. Validate: realpath($REAL_SRC) starts with realpath($WORKSPACE_ROOT) ✓
# 2. Derive module name from path relative to workspace root
# 3. Report errors using paths relative to workspace root
{lean} --root="$WORKSPACE_ROOT" {src} -c {out}
""".format(
            lean = lean.path,
            src = src.path,
            short_path = src.short_path,
            out = c_file.path,
        ),
        inputs = [src, lean],
        outputs = [c_file],
        use_default_shell_env = True,
    )

def _lean_binary_impl_experimental(ctx):
    """Experimental lean_binary implementation using workspace root approach."""
    toolchain = ctx.toolchains["@rules_lean//lean:toolchain_type"]
    lean = toolchain.lean
    leanc = toolchain.leanc

    src = ctx.file.src
    if not src.path.endswith(".lean"):
        fail("Source file must have .lean extension, got: {}".format(src.path))

    # Output files
    name = ctx.label.name
    c_file = ctx.actions.declare_file(name + ".c")
    executable = ctx.actions.declare_file(name)

    # Compile .lean to .c using workspace root approach
    _lean_compile_with_workspace_root(ctx, src, lean, c_file)

    # Link .c to executable using leanc
    link_args = ctx.actions.args()
    link_args.add("-o")
    link_args.add(executable)
    link_args.add(c_file)

    ctx.actions.run(
        mnemonic = "LeanLink",
        executable = leanc,
        arguments = [link_args],
        inputs = [c_file],
        outputs = [executable],
        tools = [leanc],
    )

    return [
        DefaultInfo(
            executable = executable,
            files = depset([executable]),
            runfiles = ctx.runfiles(files = [executable]),
        ),
    ]

lean_binary_experimental = rule(
    implementation = _lean_binary_impl_experimental,
    attrs = {
        "src": attr.label(
            doc = "The Lean source file to compile",
            allow_single_file = [".lean"],
            mandatory = True,
        ),
    },
    executable = True,
    toolchains = ["@rules_lean//lean:toolchain_type"],
)
