"""Implementation of lean_module rule for compiling individual Lean modules."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

LeanModuleInfo = provider(
    doc = "Information about a compiled Lean module.",
    fields = {
        "module_name": "string: Lean module name (e.g., 'App.Config')",
        "olean": "File: compiled .olean file",
        "ilean": "File: incremental Lean data file (.ilean)",
        "c_source": "File: generated C source file",
        "object_file": "File: compiled object file (.o)",
        "transitive_oleans": "depset: all transitive .olean and related files",
        "transitive_objects": "depset: all transitive object files",
    },
)

def _lean_module_impl(ctx):
    """Compiles a single .lean file to .olean and .c, then compiles .c to .o."""
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

    # Derive module name from source path if not specified
    module_name = ctx.attr.module_name
    if not module_name:
        # Use target name as module name by default
        module_name = ctx.label.name

    # Check if this is a Lean 4 module system file (uses `module` keyword)
    is_module = ctx.attr.is_module

    # Output files - use module path structure for olean/ilean so LEAN_PATH works
    name = ctx.label.name
    module_path_base = module_name.replace(".", "/")
    olean_file = ctx.actions.declare_file(module_path_base + ".olean")
    ilean_file = ctx.actions.declare_file(module_path_base + ".ilean")
    c_file = ctx.actions.declare_file(name + ".c")
    setup_file = ctx.actions.declare_file(name + ".setup.json")

    # Module system files generate additional outputs
    olean_private_file = None
    olean_server_file = None
    ir_file = None
    if is_module:
        olean_private_file = ctx.actions.declare_file(module_path_base + ".olean.private")
        olean_server_file = ctx.actions.declare_file(module_path_base + ".olean.server")
        ir_file = ctx.actions.declare_file(module_path_base + ".ir")

    # Collect transitive oleans from deps for LEAN_PATH
    dep_oleans = []
    dep_olean_roots = []
    for dep in ctx.attr.deps:
        if LeanModuleInfo in dep:
            info = dep[LeanModuleInfo]
            dep_oleans.extend(info.transitive_oleans.to_list())
            # Compute the root directory for this olean
            # The olean path is like: bazel-out/.../Utils/Math.olean
            # For module Utils.Math, we need the root (before Utils/)
            # We can derive it from the olean path and module name
            olean = info.olean
            dep_module = info.module_name
            dep_module_path = dep_module.replace(".", "/") + ".olean"
            # olean.path ends with dep_module_path, extract the root
            if olean.path.endswith(dep_module_path):
                root = olean.path[:-(len(dep_module_path) + 1)]  # +1 for the /
                if root and root not in dep_olean_roots:
                    dep_olean_roots.append(root)

    # Build LEAN_PATH from dependency olean root directories
    lean_path = ":".join(dep_olean_roots) if dep_olean_roots else ""

    # Copy source file to work around Bazel symlink issues (same as in lean_binary)
    # See lean/private/rules.bzl for detailed explanation
    #
    # For modules, use a structure based on the module name to compute --root correctly:
    # Module Utils.Math -> path Utils/Math.lean, --root is the parent of Utils/
    module_path = module_name.replace(".", "/") + ".lean"
    src_copy = ctx.actions.declare_file(name + "_lean_src/" + module_path)

    # The root directory is the prefix before the module path
    root_dir = src_copy.path[:-(len(module_path) + 1)]

    # Create setup JSON file
    # isModule=true: Uses Lean 4 module system, requires `module` keyword and `public section`
    #   - Generates .ir, .olean.private, .olean.server files
    #   - Only explicitly `public` definitions are exported
    # isModule=false: Traditional Lean code
    #   - All non-private definitions are automatically exported
    #   - No additional files generated
    setup_json = '{{"name": "{module}", "isModule": {is_module}, "importArts": {{}}, "dynlibs": [], "plugins": [], "options": {{}}}}'.format(
        module = module_name,
        is_module = "true" if is_module else "false",
    )

    # Compile .lean to .olean, .ilean, and .c (plus extra files if is_module)
    compile_cmd = "mkdir -p {src_dir} && cp -L {src} {src_copy} && echo '{setup_json}' > {setup_file} && {lean} --root={root} {src_copy} -o {olean} -i {ilean} -c {c_out} --setup {setup_file}"

    # Build environment with LEAN_PATH if we have dependencies
    env = {}
    if lean_path:
        env["LEAN_PATH"] = lean_path

    # Build output list
    outputs = [olean_file, ilean_file, c_file, src_copy, setup_file]
    if is_module:
        outputs.extend([olean_private_file, olean_server_file, ir_file])

    ctx.actions.run_shell(
        mnemonic = "LeanModule",
        command = compile_cmd.format(
            lean = lean.path,
            src = src.path,
            src_copy = src_copy.path,
            src_dir = src_copy.dirname,
            root = root_dir,
            olean = olean_file.path,
            ilean = ilean_file.path,
            c_out = c_file.path,
            setup_json = setup_json,
            setup_file = setup_file.path,
        ),
        inputs = [src, lean] + dep_oleans,
        outputs = outputs,
        env = env,
        use_default_shell_env = True,
    )

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

    # Get the object file from compilation outputs
    object_files = compilation_outputs.objects
    if not object_files:
        fail("No object file produced for {}".format(name))
    object_file = object_files[0]

    # Build transitive depsets
    direct_oleans = [olean_file, ilean_file]
    if is_module:
        direct_oleans.extend([olean_private_file, olean_server_file, ir_file])

    transitive_oleans = depset(
        direct_oleans,
        transitive = [dep[LeanModuleInfo].transitive_oleans for dep in ctx.attr.deps if LeanModuleInfo in dep],
    )
    transitive_objects = depset(
        [object_file],
        transitive = [dep[LeanModuleInfo].transitive_objects for dep in ctx.attr.deps if LeanModuleInfo in dep],
    )

    # Build default files output
    default_files = [olean_file, ilean_file, c_file, object_file]
    if is_module:
        default_files.extend([olean_private_file, olean_server_file, ir_file])

    return [
        DefaultInfo(
            files = depset(default_files),
        ),
        LeanModuleInfo(
            module_name = module_name,
            olean = olean_file,
            ilean = ilean_file,
            c_source = c_file,
            object_file = object_file,
            transitive_oleans = transitive_oleans,
            transitive_objects = transitive_objects,
        ),
    ]

lean_module = rule(
    implementation = _lean_module_impl,
    attrs = {
        "src": attr.label(
            doc = "The Lean source file to compile",
            allow_single_file = [".lean"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Other lean_module targets this module depends on",
            providers = [LeanModuleInfo],
            default = [],
        ),
        "module_name": attr.string(
            doc = "Lean module name (e.g., 'App.Config'). Defaults to target name.",
            default = "",
        ),
        "is_module": attr.bool(
            doc = """Whether this is a Lean 4 module system file (uses `module` keyword).

Set to True for files that:
- Start with the `module` keyword
- Use `public section` or `public import`
- Are part of a package following Lean 4 module conventions

When True:
- Generates .ir, .olean.private, .olean.server files
- Only explicitly `public` definitions are exported

When False (default):
- All non-private definitions are automatically exported
- Standard Lean 4 code without module system
""",
            default = False,
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    toolchains = ["@rules_lean//lean:toolchain_type"] + use_cc_toolchain(),
    fragments = ["cpp"],
    doc = """Compiles a single Lean source file to .olean and .o.

This rule compiles a .lean file, producing:
- .olean file for downstream Lean compilation
- .c file (intermediate)
- .o file for linking

Example:
    lean_module(
        name = "Utils",
        src = "Utils.lean",
    )

    lean_module(
        name = "Main",
        src = "Main.lean",
        deps = [":Utils"],
    )
""",
)
