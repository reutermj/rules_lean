"""Repository rule for auto-generating lean_module targets from import dependencies."""

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
    """Check if there's a cycle in the dependency graph.

    Uses a simple topological sort approach - if we can't sort all nodes,
    there's a cycle.

    Args:
        modules: Dict of module_name -> {"local_deps": [names]}

    Returns:
        True if cycle exists, False otherwise.
    """
    # Build in-degree map
    in_degree = {m: 0 for m in modules}
    for mod in modules:
        for dep in modules[mod].get("local_deps", []):
            if dep in in_degree:
                in_degree[dep] = in_degree[dep] + 1

    # Find all nodes with in-degree 0
    queue = [m for m in in_degree if in_degree[m] == 0]
    processed = 0

    # Process nodes in topological order
    for _ in range(len(modules) + 1):  # bounded iteration
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

    # If we couldn't process all nodes, there's a cycle
    return processed != len(modules)

def _parse_external_deps(deps):
    """Parse external dependency labels to extract package info.

    Args:
        deps: List of labels like ["@lake//:Cli", "@lake//:Std"]

    Returns:
        Dict mapping package name to repo (e.g., {"Cli": "@lake", "Std": "@lake"})
    """
    external_packages = {}
    for dep in deps:
        # Parse "@repo//:Target" format
        if dep.startswith("@") and "//:" in dep:
            parts = dep.split("//:")
            repo = parts[0]  # "@lake"
            target = parts[1]  # "Cli" or "Cli.Basic"
            # Extract the top-level package name (before any dots)
            pkg_name = target.split(".")[0]
            external_packages[pkg_name] = repo
    return external_packages

def _generate_build_file(modules):
    """Generate BUILD.bazel content for lean_module targets."""
    lines = [
        'load("@rules_lean//lean:defs.bzl", "lean_module")',
        "",
    ]

    for module_name in sorted(modules.keys()):
        info = modules[module_name]
        # Use the local path (symlinked into the repo)
        src_local = info["src_local"]

        # Combine local deps with external deps
        local_deps = info.get("local_deps", [])
        external_deps = info.get("external_deps", [])

        all_deps = ['":' + d + '"' for d in sorted(local_deps)]
        all_deps.extend(['"' + d + '"' for d in sorted(external_deps)])

        deps_str = ""
        if all_deps:
            deps_str = "\n    deps = [" + ", ".join(all_deps) + "],"

        # Reference the local symlinked source file
        target_def = 'lean_module(\n    name = "{name}",\n    src = ":{src}",{deps}\n    visibility = ["//visibility:public"],\n)\n'
        lines.append(target_def.format(name = module_name, src = src_local, deps = deps_str))

    return "\n".join(lines)

def _lean_project_impl(rctx):
    """Implementation of the lean_project repository rule."""
    lean_binary = rctx.path(rctx.attr.lean_binary)
    workspace_root = rctx.workspace_root

    project_root = workspace_root
    if rctx.attr.root:
        project_root = workspace_root.get_child(rctx.attr.root)

    lean_files = _glob_lean_files(rctx, project_root)

    if not lean_files:
        empty_msg = "# No .lean files found in " + (rctx.attr.root if rctx.attr.root else ".") + "\n"
        rctx.file("BUILD.bazel", empty_msg)
        return

    # Parse external dependencies to know which packages are available
    external_packages = _parse_external_deps(rctx.attr.deps)

    # If there are external deps, run `lake update` to download packages
    # and add them to LEAN_PATH for import resolution
    lean_path_parts = [str(project_root)]

    if external_packages:
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

        # Add downloaded package directories to LEAN_PATH
        lake_packages_dir = workspace_root.get_child(".lake").get_child("packages")
        for pkg_name in external_packages.keys():
            pkg_dir = lake_packages_dir.get_child(pkg_name)
            if pkg_dir.exists:
                lean_path_parts.append(str(pkg_dir))

    lean_path_env = ":".join(lean_path_parts)

    modules = {}
    project_root_str = str(project_root)

    for f in lean_files:
        module_name = _path_to_module_name(f, project_root)

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

        # Compute the relative path within the project root
        rel_path = f
        if f.startswith(project_root_str):
            rel_path = f[len(project_root_str):].lstrip("/")

        # Symlink the source file into this repository
        # Convert module name to directory path: Utils.Math -> Utils/Math.lean
        local_path = module_name.replace(".", "/") + ".lean"
        rctx.symlink(f, local_path)

        modules[module_name] = {
            "src": f,
            "src_local": local_path,
            "deps": dep_oleans,
        }

    # Resolve dependencies - both local and external
    for mod_name in modules:
        info = modules[mod_name]
        local_deps = []
        external_deps = []

        for olean_path in info["deps"]:
            if olean_path.startswith(project_root_str):
                # Local dependency within this project
                rel_path = olean_path[len(project_root_str):].lstrip("/")
                if rel_path.endswith(".olean"):
                    rel_path = rel_path[:-6]
                dep_module = rel_path.replace("/", ".")
                if dep_module != mod_name:
                    local_deps.append(dep_module)
            else:
                # Check if this is an external package dependency
                # lean --deps outputs paths like /<pkg>/<module>.olean
                # We need to match against external package names
                for pkg_name, repo in external_packages.items():
                    # Check if olean path contains the package name
                    # Path format: .../packages/Cli/Cli/Basic.olean
                    if "/" + pkg_name + "/" in olean_path or olean_path.endswith("/" + pkg_name + ".olean"):
                        # Extract module name from olean path
                        # Find the package directory in the path
                        pkg_marker = "/" + pkg_name + "/"
                        if pkg_marker in olean_path:
                            idx = olean_path.find(pkg_marker) + len(pkg_marker)
                            rel_olean = olean_path[idx:]
                            if rel_olean.endswith(".olean"):
                                rel_olean = rel_olean[:-6]
                            dep_module = rel_olean.replace("/", ".")
                            external_dep = "{repo}//:{module}".format(repo = repo, module = dep_module)
                            external_deps.append(external_dep)
                        elif olean_path.endswith("/" + pkg_name + ".olean"):
                            # Top-level module like Cli.olean
                            external_dep = "{repo}//:{pkg}".format(repo = repo, pkg = pkg_name)
                            external_deps.append(external_dep)
                        break

        info["local_deps"] = _dedupe(local_deps)
        info["external_deps"] = _dedupe(external_deps)

    if _has_cycle(modules):
        fail("Circular imports detected in project")

    build_content = _generate_build_file(modules)
    rctx.file("BUILD.bazel", build_content)

lean_project = repository_rule(
    implementation = _lean_project_impl,
    attrs = {
        "root": attr.string(default = ""),
        "lean_binary": attr.label(mandatory = True, allow_single_file = True),
        "deps": attr.string_list(default = []),
    },
)
