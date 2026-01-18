"""Implementation of the lean_module rule."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

# Provider for Lean module compilation outputs
LeanModuleInfo = provider(
    doc = "Information about a compiled Lean module.",
    fields = {
        "module_name": "Fully qualified module name (e.g., 'MyLib.Core')",
        "olean": "The .olean file (compiled interface)",
        "ilean": "The .ilean file (incremental lean interface)",
        "c_source": "The generated .c file",
        "c_object": "The compiled .o file",
        "transitive_oleans": "depset of all transitive .olean files",
        "transitive_c_objects": "depset of all transitive .o files",
    },
)

def _lean_module_compile(ctx, src, lean, olean, ilean, c_file, dep_infos, transitive_oleans):
    """Compiles a .lean file to .olean, .ilean, and .c files.

    Args:
        ctx: The rule context.
        src: The source .lean file.
        lean: The lean compiler executable.
        olean: The output .olean file.
        ilean: The output .ilean file.
        c_file: The output .c file.
        dep_infos: List of LeanModuleInfo from direct dependencies.
        transitive_oleans: List of all transitive .olean files.

    Returns:
        The copied source file (intermediate output for path handling).
    """

    # See comments in rules.bzl for why we copy the source file.
    # The copy preserves the workspace-relative path for correct module naming.
    # For external repos, short_path starts with "../<repo>/" or "external/<repo>/"
    # We need to compute a path relative to the repository root for the module name
    src_short = src.short_path

    # Handle external repository sources - extract just the path within the repo
    if src_short.startswith("../"):
        # ../rules_lean++lean+lean_deps/Cli/Basic.lean -> Cli/Basic.lean
        parts = src_short.split("/", 2)  # ["..", "<repo>", "path/to/file.lean"]
        if len(parts) >= 3:
            src_short = parts[2]
    elif src_short.startswith("external/"):
        # external/rules_lean++lean+lean_deps/Cli/Basic.lean -> Cli/Basic.lean
        parts = src_short.split("/", 2)  # ["external", "<repo>", "path/to/file.lean"]
        if len(parts) >= 3:
            src_short = parts[2]

    src_copy = ctx.actions.declare_file(ctx.label.name + "_lean_src/" + src_short)
    root_dir = src_copy.path[:-(len(src_short) + 1)]

    # Build LEAN_PATH from dependency oleans
    # LEAN_PATH tells lean where to find .olean files for imports
    # For a module like lib.Greeter with olean at bazel-bin/lib/Greeter.olean,
    # LEAN_PATH should point to bazel-bin (the root where lib/Greeter.olean is found)
    olean_roots = {}

    # Use direct dep_infos to compute olean roots from module names
    for info in dep_infos:
        # Compute the olean root by stripping the module path from the full path
        # e.g., for module "lib.Greeter" and path "bazel-bin/lib/Greeter.olean"
        # module_path = "lib/Greeter.olean", so root = "bazel-bin"
        module_path = info.module_name.replace(".", "/") + ".olean"
        olean_path = info.olean.path
        if olean_path.endswith("/" + module_path):
            olean_root = olean_path[:-(len(module_path) + 1)]
            olean_roots[olean_root] = True
        else:
            # Fallback to dirname if path doesn't match expected pattern
            olean_roots[info.olean.dirname] = True

    lean_path = ":".join(sorted(olean_roots.keys())) if olean_roots else ""

    # Build the compilation command
    # lean --root=<root> <src> -o <olean> --ilean=<ilean> -c <c_file>
    setup_cmd = "mkdir -p {src_dir} && cp -L {src} {src_copy}".format(
        src_dir = src_copy.dirname,
        src = src.path,
        src_copy = src_copy.path,
    )

    # LEAN_PATH must be on the same line as the lean command (not &&-separated)
    # to properly set the environment variable for lean
    lean_env = "LEAN_PATH={lean_path} ".format(lean_path = lean_path) if lean_path else ""

    lean_cmd = "{lean_env}{lean} --root={root} {src_copy} -o {olean} -i {ilean} -c {c_file}".format(
        lean_env = lean_env,
        lean = lean.path,
        root = root_dir,
        src_copy = src_copy.path,
        olean = olean.path,
        ilean = ilean.path,
        c_file = c_file.path,
    )

    cmd_parts = [setup_cmd, lean_cmd]

    ctx.actions.run_shell(
        mnemonic = "LeanCompile",
        command = " && ".join(cmd_parts),
        inputs = [src, lean] + transitive_oleans,
        outputs = [olean, ilean, c_file, src_copy],
        use_default_shell_env = True,
    )

    return src_copy

def _lean_module_impl(ctx):
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

    # Collect dependency info
    dep_infos = []
    transitive_olean_depsets = []
    transitive_c_object_depsets = []

    for dep in ctx.attr.deps:
        if LeanModuleInfo in dep:
            info = dep[LeanModuleInfo]
            dep_infos.append(info)
            transitive_olean_depsets.append(info.transitive_oleans)
            transitive_c_object_depsets.append(info.transitive_c_objects)

    # Output files
    # The olean path must match the module name structure so Lean can find imports.
    # e.g., module Cli.Basic -> olean at Cli/Basic.olean (relative to output root)
    #
    # For local packages like //lib:Greeter, source is lib/Greeter.lean, module is lib.Greeter
    # but we're in package "lib" so olean should be Greeter.olean (Bazel adds lib/ prefix)
    #
    # For external packages like @lean_deps//:Cli.Basic, source is Cli/Basic.lean, module is Cli.Basic
    # we're in package "" (root) so olean should be Cli/Basic.olean
    name = ctx.label.name

    # Compute the olean path from the source path (which matches module structure)
    # Handle external repo prefixes
    src_path = src.short_path
    if src_path.startswith("../"):
        parts = src_path.split("/", 2)
        if len(parts) >= 3:
            src_path = parts[2]
    elif src_path.startswith("external/"):
        parts = src_path.split("/", 2)
        if len(parts) >= 3:
            src_path = parts[2]

    # For local packages, strip the package prefix to avoid duplication
    # e.g., in //lib package, lib/Greeter.lean -> Greeter.olean (not lib/Greeter.olean)
    pkg_path = ctx.label.package
    if pkg_path and src_path.startswith(pkg_path + "/"):
        src_path = src_path[len(pkg_path) + 1:]

    olean_path = src_path.removesuffix(".lean") + ".olean"
    ilean_path = src_path.removesuffix(".lean") + ".ilean"

    olean = ctx.actions.declare_file(olean_path)
    ilean = ctx.actions.declare_file(ilean_path)
    c_file = ctx.actions.declare_file(name + ".c")

    # Collect transitive oleans for compilation inputs
    transitive_oleans = depset(transitive = transitive_olean_depsets).to_list()

    # Compile .lean to .olean, .ilean, .c
    _lean_module_compile(ctx, src, lean, olean, ilean, c_file, dep_infos, transitive_oleans)

    # Compile .c to .o using CC toolchain
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

    # Get the .o file from compilation outputs
    # cc_common.compile returns object files in compilation_outputs.objects
    object_files = compilation_outputs.objects
    if len(object_files) != 1:
        fail("Expected exactly one object file, got: {}".format(len(object_files)))
    c_object = object_files[0]

    # Build transitive depsets
    transitive_oleans = depset(
        direct = [olean],
        transitive = transitive_olean_depsets,
    )
    transitive_c_objects = depset(
        direct = [c_object],
        transitive = transitive_c_object_depsets,
    )

    # Module name is derived from the source path
    # For external repos, we strip the repo prefix to get the true module name
    # This matches the Gazelle extension's naming convention
    src_path = src.short_path
    if src_path.startswith("../"):
        parts = src_path.split("/", 2)
        if len(parts) >= 3:
            src_path = parts[2]
    elif src_path.startswith("external/"):
        parts = src_path.split("/", 2)
        if len(parts) >= 3:
            src_path = parts[2]
    module_name = src_path.removesuffix(".lean").replace("/", ".")

    return [
        DefaultInfo(
            files = depset([olean, ilean, c_file, c_object]),
        ),
        LeanModuleInfo(
            module_name = module_name,
            olean = olean,
            ilean = ilean,
            c_source = c_file,
            c_object = c_object,
            transitive_oleans = transitive_oleans,
            transitive_c_objects = transitive_c_objects,
        ),
    ]

lean_module = rule(
    implementation = _lean_module_impl,
    doc = """Compiles a single Lean source file to .olean and .c/.o files.

This rule is typically generated by Gazelle. Each .lean file gets its own
lean_module target, with deps populated based on import statements.

Example:
    lean_module(
        name = "MyLib.Core",
        src = "MyLib/Core.lean",
        deps = [":MyLib.Utils"],
    )
""",
    attrs = {
        "src": attr.label(
            doc = "The Lean source file to compile.",
            allow_single_file = [".lean"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Other lean_module targets this module depends on.",
            providers = [LeanModuleInfo],
            default = [],
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    toolchains = ["@rules_lean//lean:toolchain_type"] + use_cc_toolchain(),
    fragments = ["cpp"],
)
