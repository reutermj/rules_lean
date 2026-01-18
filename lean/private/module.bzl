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

def _lean_module_compile(ctx, src, lean, olean, ilean, c_file, dep_oleans):
    """Compiles a .lean file to .olean, .ilean, and .c files.

    Args:
        ctx: The rule context.
        src: The source .lean file.
        lean: The lean compiler executable.
        olean: The output .olean file.
        ilean: The output .ilean file.
        c_file: The output .c file.
        dep_oleans: List of .olean files from dependencies.

    Returns:
        The copied source file (intermediate output for path handling).
    """

    # See comments in rules.bzl for why we copy the source file.
    # The copy preserves the workspace-relative path for correct module naming.
    src_copy = ctx.actions.declare_file(ctx.label.name + "_lean_src/" + src.short_path)
    root_dir = src_copy.path[:-(len(src.short_path) + 1)]

    # Build LEAN_PATH from dependency oleans
    # LEAN_PATH tells lean where to find .olean files for imports
    olean_dirs = {}
    for olean_file in dep_oleans:
        # Get the directory containing the olean
        olean_dirs[olean_file.dirname] = True
    lean_path = ":".join(sorted(olean_dirs.keys())) if olean_dirs else ""

    # Build the compilation command
    # lean --root=<root> <src> -o <olean> --ilean=<ilean> -c <c_file>
    cmd_parts = [
        "mkdir -p {src_dir} && cp -L {src} {src_copy}".format(
            src_dir = src_copy.dirname,
            src = src.path,
            src_copy = src_copy.path,
        ),
    ]

    if lean_path:
        cmd_parts.append("LEAN_PATH={lean_path}".format(lean_path = lean_path))

    cmd_parts.append(
        "{lean} --root={root} {src_copy} -o {olean} -i {ilean} -c {c_file}".format(
            lean = lean.path,
            root = root_dir,
            src_copy = src_copy.path,
            olean = olean.path,
            ilean = ilean.path,
            c_file = c_file.path,
        ),
    )

    ctx.actions.run_shell(
        mnemonic = "LeanCompile",
        command = " && ".join(cmd_parts),
        inputs = [src, lean] + dep_oleans,
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

    # Collect transitive oleans from dependencies
    dep_oleans = []
    transitive_olean_depsets = []
    transitive_c_object_depsets = []

    for dep in ctx.attr.deps:
        if LeanModuleInfo in dep:
            info = dep[LeanModuleInfo]
            dep_oleans.append(info.olean)
            transitive_olean_depsets.append(info.transitive_oleans)
            transitive_c_object_depsets.append(info.transitive_c_objects)

    # Output files
    name = ctx.label.name
    olean = ctx.actions.declare_file(name + ".olean")
    ilean = ctx.actions.declare_file(name + ".ilean")
    c_file = ctx.actions.declare_file(name + ".c")

    # Compile .lean to .olean, .ilean, .c
    _lean_module_compile(ctx, src, lean, olean, ilean, c_file, dep_oleans)

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

    # Module name is derived from the workspace-relative source path
    # This matches the Gazelle extension's naming convention
    module_name = src.short_path.removesuffix(".lean").replace("/", ".")

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
