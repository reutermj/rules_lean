"""Implementation of Lean build rules."""

# Module naming and Lean's --root flag
# =====================================
#
# Lean's --root flag sets the package root directory. Lean uses this for:
#   1. Calculating module names from file paths
#   2. Validating source files are contained within the project
#
# Module names are derived from the path relative to --root:
#   --root=/workspace, file=/workspace/proj/Foo.lean → module proj.Foo
#
# We use the workspace root as --root so module names match source paths:
#   //proj1/utils/Foo.lean → module proj1.utils.Foo
#   //proj2/utils/Foo.lean → module proj2.utils.Foo
#
# This provides natural namespacing in monorepos (both files can coexist).
#
# Symlink workaround
# ------------------
# Lean enforces: realpath(source_file) must start with realpath(--root)
#
# Bazel's execroot uses symlinks:
#   execroot/proj/Foo.lean -> /home/user/myrepo/proj/Foo.lean
#
# When we pass --root=. (execroot) and proj/Foo.lean, Lean resolves:
#   realpath(proj/Foo.lean) = /home/user/myrepo/proj/Foo.lean
#   realpath(--root)        = /home/.../sandbox/.../execroot/_main/
#
# These don't match, so Lean fails with:
#   "input file '/home/user/myrepo/proj/Foo.lean' must be contained in
#    root directory (/home/.../execroot/_main/)"
#
# Fix: Copy source files (cp -L dereferences symlinks) to preserve the
# directory structure under the execroot. The copy is placed at the same
# relative path so the module name is correct:
#   execroot/proj/Foo.lean (real file) → module proj.Foo
def _lean_compile(ctx, src, lean, c_file):
    """Compiles a .lean file to a .c file.

    Handles Bazel's symlink-based execroot by copying the source file to ensure
    Lean's path validation succeeds. The copy preserves the workspace-relative
    path so the module name is derived correctly.

    Args:
        ctx: The rule context.
        src: The source .lean file.
        lean: The lean compiler executable.
        c_file: The output .c file to produce.

    Returns:
        The copied source file (an intermediate output).
    """

    # Preserve the workspace-relative path for correct module naming.
    # src.short_path is the path relative to the workspace root (e.g., "proj/Foo.lean").
    # We prefix with the target name to avoid conflicts when multiple targets
    # use the same source file.
    src_copy = ctx.actions.declare_file(ctx.label.name + "_lean_src/" + src.short_path)

    # The root directory for --root is the parent of the copied source tree.
    # This ensures the module name matches the workspace-relative path:
    #   src_copy = bazel-out/.../hello_lean_src/proj/Foo.lean
    #   root     = bazel-out/.../hello_lean_src
    #   module   = proj.Foo
    root_dir = src_copy.path[:-(len(src.short_path) + 1)]  # Remove "/proj/Foo.lean"

    ctx.actions.run_shell(
        mnemonic = "LeanCompile",
        command = "mkdir -p {src_dir} && cp -L {src} {src_copy} && {lean} --root={root} {src_copy} -c {out}".format(
            lean = lean.path,
            src = src.path,
            src_copy = src_copy.path,
            src_dir = src_copy.dirname,
            root = root_dir,
            out = c_file.path,
        ),
        inputs = [src, lean],
        outputs = [c_file, src_copy],
        use_default_shell_env = True,
    )
    return src_copy

def _lean_binary_impl(ctx):
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

    # Compile .lean to .c
    _lean_compile(ctx, src, lean, c_file)

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

lean_binary = rule(
    implementation = _lean_binary_impl,
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
