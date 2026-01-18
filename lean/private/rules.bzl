"""Implementation of Lean build rules."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

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
    lean_toolchain = ctx.toolchains["@rules_lean//lean:toolchain_type"]
    lean = lean_toolchain.lean

    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    src = ctx.file.src
    if not src.path.endswith(".lean"):
        fail("Source file must have .lean extension, got: {}".format(src.path))

    # Output files
    name = ctx.label.name
    c_file = ctx.actions.declare_file(name + ".c")

    # Compile .lean to .c
    _lean_compile(ctx, src, lean, c_file)

    # Compile .c to .o using CC toolchain
    # Lean-generated C code contains unused variables (e.g., `lean_object* in;`)
    # that are artifacts of the code generator. Suppress -Wunused-variable.
    _compilation_context, compilation_outputs = cc_common.compile(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = [c_file],
        includes = [lean_toolchain.lean_include],
        additional_inputs = lean_toolchain.headers.to_list(),
        name = name,
        user_compile_flags = ["-Wno-unused-variable"],
    )

    # Link .o to executable with Lean runtime libraries
    #
    # Library search paths for Lean distribution
    lib_paths = [
        "-L" + lean_toolchain.lean_lib,
        "-L" + lean_toolchain.support_lib,
    ]

    # Lean runtime libraries with circular dependency handling
    #
    # --start-group/--end-group tell the linker to iterate until all symbols
    # resolve, handling circular dependencies between libraries. Without this,
    # link order would matter and some symbols might not be found.
    #
    # libleancpp.a and libLean.a have mutual dependencies (C++ runtime calls
    # into Lean runtime and vice versa), as do libInit.a and libleanrt.a.
    lean_runtime_libs = [
        "-Wl,--start-group",
        "-lleancpp",
        "-lLean",
        "-Wl,--end-group",
        "-lStd",
        "-Wl,--start-group",
        "-lInit",
        "-lleanrt",
        "-Wl,--end-group",
    ]

    # Static C++ runtime from Lean distribution
    #
    # Lean's libleancpp.a is compiled with clang/libc++ and uses the libc++ ABI
    # (std::__1:: namespace). We must link against the libc++ from Lean's
    # distribution, not the system's libstdc++.
    #
    # -Bstatic forces static linking for these specific libraries, ensuring
    # the binary doesn't depend on system libc++.so at runtime.
    # -Bdynamic restores default behavior for subsequent libraries.
    cxx_runtime_libs = [
        "-Wl,-Bstatic",
        "-lc++",
        "-lc++abi",
    ]

    # Static support libraries from Lean distribution
    #
    # GMP (arbitrary precision arithmetic) and libuv (async I/O) are bundled
    # with Lean. Link statically to avoid runtime dependencies.
    support_libs = [
        "-lgmp",
        "-luv",
        "-Wl,-Bdynamic",
    ]

    # System libraries (dynamically linked)
    system_libs = [
        "-lm",
        "-lpthread",
        "-ldl",
        "-lrt",
    ]

    link_flags = lib_paths + lean_runtime_libs + cxx_runtime_libs + support_libs + system_libs

    # Link object files into final executable
    #
    # user_link_flags: Passed to the linker command line. These specify library
    # search paths (-L) and libraries to link (-l). The linker resolves -l flags
    # by searching -L paths for matching .a/.so files.
    #
    # additional_inputs: Files that must exist for the action to succeed, but
    # aren't automatically discovered by the linker. The .a files referenced by
    # -l flags must be declared here so Bazel knows to make them available in
    # the sandbox during linking.
    linking_outputs = cc_common.link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        compilation_outputs = compilation_outputs,
        output_type = "executable",
        name = name,
        user_link_flags = link_flags,
        additional_inputs = lean_toolchain.libs.to_list(),
    )

    return [
        DefaultInfo(
            executable = linking_outputs.executable,
            files = depset([linking_outputs.executable]),
            runfiles = ctx.runfiles(files = [linking_outputs.executable]),
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
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    executable = True,
    toolchains = ["@rules_lean//lean:toolchain_type"] + use_cc_toolchain(),
    fragments = ["cpp"],
)
