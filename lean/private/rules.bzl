"""Implementation of Lean build rules."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//lean/private:module.bzl", "LeanModuleInfo")

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
def _lean_compile(ctx, src, lean, c_file, dep_oleans = [], lean_path = ""):
    """Compiles a .lean file to a .c file.

    Handles Bazel's symlink-based execroot by copying the source file to ensure
    Lean's path validation succeeds. The copy preserves the workspace-relative
    path so the module name is derived correctly.

    Args:
        ctx: The rule context.
        src: The source .lean file.
        lean: The lean compiler executable.
        c_file: The output .c file to produce.
        dep_oleans: List of .olean files from dependencies.
        lean_path: LEAN_PATH environment variable value for import resolution.

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

    # Derive module name from source path (remove .lean extension and replace / with .)
    module_name = src.short_path
    if module_name.endswith(".lean"):
        module_name = module_name[:-5]
    module_name = module_name.replace("/", ".")

    # Setup file for --setup flag
    setup_file = ctx.actions.declare_file(ctx.label.name + ".setup.json")

    # Create setup JSON with isModule=false for binary entry points
    # This generates the C main() function while still allowing imports of modules compiled with isModule=true
    setup_json = '{{"name": "{module}", "isModule": false, "importArts": {{}}, "dynlibs": [], "plugins": [], "options": {{}}}}'.format(
        module = module_name,
    )

    compile_cmd = "mkdir -p {src_dir} && cp -L {src} {src_copy} && echo '{setup_json}' > {setup_file} && {lean} --root={root} {src_copy} -c {out} --setup {setup_file}"

    # Build environment with LEAN_PATH if we have dependencies
    env = {}
    if lean_path:
        env["LEAN_PATH"] = lean_path

    ctx.actions.run_shell(
        mnemonic = "LeanCompile",
        command = compile_cmd.format(
            lean = lean.path,
            src = src.path,
            src_copy = src_copy.path,
            src_dir = src_copy.dirname,
            root = root_dir,
            out = c_file.path,
            setup_json = setup_json,
            setup_file = setup_file.path,
        ),
        inputs = [src, lean] + dep_oleans,
        outputs = [c_file, src_copy, setup_file],
        env = env,
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

    # Collect transitive oleans and objects from deps
    dep_oleans = []
    dep_olean_roots = {}  # Use dict for deduplication, key=root, value=True
    dep_objects = []
    for dep in ctx.attr.deps:
        if LeanModuleInfo in dep:
            info = dep[LeanModuleInfo]
            dep_oleans.extend(info.transitive_oleans.to_list())
            dep_objects.extend(info.transitive_objects.to_list())

    # Compute root directories from ALL transitive olean files
    # This ensures external package paths (like @lake//:Cli) are included in LEAN_PATH
    # We collect all possible root directories by walking up from each olean file
    for olean in dep_oleans:
        if olean.path.endswith(".olean"):
            # Add the directory containing the olean file
            # For nested modules like Cli/Basic.olean, we also need the parent directory
            path = olean.dirname
            if path not in dep_olean_roots:
                dep_olean_roots[path] = True
            # Also add parent directories (for nested modules)
            # Walk up max 5 levels to find package roots
            for _ in range(5):
                if "/" in path:
                    path = path.rsplit("/", 1)[0]
                    if path.endswith("bazel-out") or not path:
                        break
                    if path not in dep_olean_roots:
                        dep_olean_roots[path] = True
                else:
                    break

    # Build LEAN_PATH from dependency olean root directories
    lean_path = ":".join(dep_olean_roots.keys()) if dep_olean_roots else ""

    # Output files
    name = ctx.label.name
    c_file = ctx.actions.declare_file(name + ".c")

    # Compile .lean to .c (with LEAN_PATH for imports)
    _lean_compile(ctx, src, lean, c_file, dep_oleans, lean_path)

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

    # Add dependency object files to linker inputs
    # These are the compiled .o files from lean_module deps
    dep_object_flags = [obj.path for obj in dep_objects]

    link_flags = dep_object_flags + lib_paths + lean_runtime_libs + cxx_runtime_libs + support_libs + system_libs

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
        additional_inputs = lean_toolchain.libs.to_list() + dep_objects,
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
        "deps": attr.label_list(
            doc = "lean_module targets this binary depends on",
            providers = [LeanModuleInfo],
            default = [],
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    executable = True,
    toolchains = ["@rules_lean//lean:toolchain_type"] + use_cc_toolchain(),
    fragments = ["cpp"],
)
