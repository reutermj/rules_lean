"""Repository rule for creating @lake repository with all external packages."""

def _glob_lean_files(rctx, root):
    """Recursively find all .lean files under root."""
    result = rctx.execute(["find", str(root), "-name", "*.lean", "-type", "f"])
    if result.return_code != 0:
        fail("Failed to glob .lean files: " + result.stderr)
    return [line.strip() for line in result.stdout.split("\n") if line.strip()]

def _path_to_module_name(path, root):
    """Convert file path to Lean module name."""
    root_str = str(root)
    path_str = str(path)

    # Get path relative to root
    rel = path_str
    if path_str.startswith(root_str):
        rel = path_str[len(root_str):].lstrip("/")

    # Remove .lean extension and convert / to .
    if rel.endswith(".lean"):
        rel = rel[:-5]
    return rel.replace("/", ".")

def _dedupe(items):
    """Remove duplicates while preserving order."""
    seen = {}
    result = []
    for x in items:
        if x not in seen:
            seen[x] = True
            result.append(x)
    return result

def _has_cycle(modules):
    """Check if there's a cycle in the dependency graph."""
    in_degree = {m: 0 for m in modules}
    for mod in modules:
        for dep in modules[mod].get("local_deps", []):
            if dep in in_degree:
                in_degree[dep] = in_degree[dep] + 1

    queue = [m for m in in_degree if in_degree[m] == 0]
    processed = 0

    for _ in range(len(modules) + 1):
        if not queue:
            break
        node = queue[0]
        queue = queue[1:]
        processed = processed + 1

        for dep in modules[node].get("local_deps", []):
            if dep in in_degree:
                in_degree[dep] = in_degree[dep] - 1
                if in_degree[dep] == 0:
                    queue.append(dep)

    return processed != len(modules)

def _generate_build_file(modules):
    """Generate BUILD.bazel content for lean_module targets."""
    lines = [
        'load("@rules_lean//lean:defs.bzl", "lean_module")',
        "",
    ]

    for module_name in sorted(modules.keys()):
        info = modules[module_name]
        src_local = info["src_local"]

        local_deps = info.get("local_deps", [])
        deps_str = ""
        if local_deps:
            deps_items = ['":' + d + '"' for d in sorted(local_deps)]
            deps_str = "\n    deps = [" + ", ".join(deps_items) + "],"

        # External Lake packages use Lean 4 module system (module keyword, public section)
        # so we set is_module = True to generate .ir/.olean.private/.olean.server files
        target_def = 'lean_module(\n    name = "{name}",\n    src = ":{src}",{deps}\n    is_module = True,\n    visibility = ["//visibility:public"],\n)\n'
        lines.append(target_def.format(name = module_name, src = src_local, deps = deps_str))

    return "\n".join(lines)

def _lean_lake_packages_impl(rctx):
    """Implementation of the lean_lake_packages repository rule.

    Downloads packages via `lake update` and generates lean_module targets
    for all modules across all packages.
    """
    lean_binary = rctx.path(rctx.attr.lean_binary)
    workspace_root = rctx.workspace_root

    # Derive lake path from lean path
    lean_path_str = str(lean_binary)
    lake_path = lean_path_str.rsplit("/lean", 1)[0] + "/lake"

    # Run `lake update` to download packages
    result = rctx.execute(
        [lake_path, "update"],
        working_directory = str(workspace_root),
        quiet = False,
    )
    if result.return_code != 0:
        fail("lake update failed: " + result.stderr)

    # Build LEAN_PATH with all package directories for cross-package resolution
    package_roots = []
    for pkg_name, pkg_rel_path in rctx.attr.packages.items():
        pkg_path = workspace_root.get_child(pkg_rel_path)
        package_roots.append(str(pkg_path))

    lean_path_env = ":".join(package_roots)

    # Collect all modules across all packages
    modules = {}

    for pkg_name, pkg_rel_path in rctx.attr.packages.items():
        pkg_path = workspace_root.get_child(pkg_rel_path)

        if not pkg_path.exists:
            fail("Package directory not found: " + str(pkg_path) + ". Run `bazel run //:lake_update` first.")

        lean_files = _glob_lean_files(rctx, pkg_path)
        pkg_path_str = str(pkg_path)

        for f in lean_files:
            module_name = _path_to_module_name(f, pkg_path)

            result = rctx.execute(
                [str(lean_binary), "--deps", f],
                environment = {"LEAN_PATH": lean_path_env},
                quiet = True,
            )

            if result.return_code != 0:
                fail("Failed to parse imports for " + f + ": " + result.stderr)

            dep_oleans = [
                line.strip()
                for line in result.stdout.split("\n")
                if line.strip().endswith(".olean")
            ]

            # Symlink source file into this repository under package subdirectory
            # e.g., Cli/Cli.lean, Cli/Cli/Basic.lean
            local_path = pkg_name + "/" + module_name.replace(".", "/") + ".lean"
            rctx.symlink(f, local_path)

            modules[module_name] = {
                "src": f,
                "src_local": local_path,
                "deps": dep_oleans,
                "package": pkg_name,
                "package_root": pkg_path_str,
            }

    # Resolve dependencies - within @lake, all packages can reference each other
    all_package_roots = {pkg_name: str(workspace_root.get_child(pkg_rel_path)) for pkg_name, pkg_rel_path in rctx.attr.packages.items()}

    for mod_name in modules:
        info = modules[mod_name]
        local_deps = []

        for olean_path in info["deps"]:
            # Check if this olean belongs to any of our packages
            for pkg_name, pkg_root in all_package_roots.items():
                if olean_path.startswith(pkg_root):
                    rel_path = olean_path[len(pkg_root):].lstrip("/")
                    if rel_path.endswith(".olean"):
                        rel_path = rel_path[:-6]
                    dep_module = rel_path.replace("/", ".")
                    if dep_module != mod_name and dep_module in modules:
                        local_deps.append(dep_module)
                    break

        info["local_deps"] = _dedupe(local_deps)

    if _has_cycle(modules):
        fail("Circular imports detected in Lake packages")

    build_content = _generate_build_file(modules)
    rctx.file("BUILD.bazel", build_content)

lean_lake_packages = repository_rule(
    implementation = _lean_lake_packages_impl,
    doc = """Creates @lake repository with lean_module targets for all Lake packages.

This rule downloads packages via `lake update` and generates Bazel targets
for all Lean modules found in those packages.

Args:
    packages: Dict mapping package name to relative path (e.g., {"Cli": ".lake/packages/Cli"})
    lean_binary: Label to the Lean binary for running `lean --deps`
""",
    attrs = {
        "packages": attr.string_dict(
            mandatory = True,
            doc = "Dict of package_name -> package_path relative to workspace root",
        ),
        "lean_binary": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Label to the Lean binary",
        ),
    },
)
