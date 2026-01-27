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

        local_deps = info.get("local_deps", [])
        deps_str = ""
        if local_deps:
            deps_items = ['":' + d + '"' for d in sorted(local_deps)]
            deps_str = "\n    deps = [" + ", ".join(deps_items) + "],"

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

    modules = {}
    project_root_str = str(project_root)

    for f in lean_files:
        module_name = _path_to_module_name(f, project_root)

        result = rctx.execute(
            [str(lean_binary), "--deps", f],
            environment = {"LEAN_PATH": project_root_str},
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

    # Resolve local dependencies
    for mod_name in modules:
        info = modules[mod_name]
        local_deps = []
        for olean_path in info["deps"]:
            if olean_path.startswith(project_root_str):
                rel_path = olean_path[len(project_root_str):].lstrip("/")
                if rel_path.endswith(".olean"):
                    rel_path = rel_path[:-6]
                dep_module = rel_path.replace("/", ".")
                if dep_module != mod_name:
                    local_deps.append(dep_module)
        info["local_deps"] = _dedupe(local_deps)

    if _has_cycle(modules):
        fail("Circular imports detected in project")

    build_content = _generate_build_file(modules)
    rctx.file("BUILD.bazel", build_content)

lean_project = repository_rule(
    implementation = _lean_project_impl,
    attrs = {
        "root": attr.string(default = ""),
        "lean_binary": attr.label(mandatory = True, allow_single_file = True),
    },
)
