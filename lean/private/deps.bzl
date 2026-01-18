"""Repository rule for fetching Lean dependencies via Lake."""

def _lean_deps_impl(ctx):
    """Implementation of lean_deps repository rule.

    Downloads Lean packages using Lake and generates BUILD files for them.
    """
    # 1. Copy lakefile and manifest to repository directory
    ctx.symlink(ctx.attr.lakefile, "lakefile.toml")
    ctx.symlink(ctx.attr.manifest, "lake-manifest.json")

    # 2. Parse the manifest to get package information
    manifest_content = ctx.read(ctx.attr.manifest)
    manifest = json.decode(manifest_content)

    packages = manifest.get("packages", [])
    if not packages:
        # No external packages - just create an empty BUILD file
        ctx.file("BUILD.bazel", "# No external packages\n")
        return

    # 3. Get the Lake binary from the Lean toolchain
    # For now, we'll download packages directly using git
    # In the future, we could use Lake for more sophisticated handling

    packages_dir = ".lake/packages"
    ctx.execute(["mkdir", "-p", packages_dir])

    # 4. Clone each package
    for pkg in packages:
        pkg_name = pkg["name"]
        pkg_url = pkg["url"]
        pkg_rev = pkg["rev"]
        pkg_dir = "{}/{}".format(packages_dir, pkg_name)

        # Clone the repository - we need full history to checkout specific commits
        # First try fetching just the specific commit
        result = ctx.execute(
            ["git", "clone", "--no-checkout", pkg_url, pkg_dir],
            timeout = 600,
        )
        if result.return_code != 0:
            fail("Failed to clone {}: {}".format(pkg_url, result.stderr))

        # Fetch the specific revision
        result = ctx.execute(
            ["git", "-C", pkg_dir, "fetch", "origin", pkg_rev],
            timeout = 300,
        )
        # Fetch might fail for commits (works for branches/tags), that's ok

        # Checkout the specific revision
        result = ctx.execute(
            ["git", "-C", pkg_dir, "checkout", pkg_rev],
            timeout = 60,
        )
        if result.return_code != 0:
            fail("Failed to checkout {} at {}: {}".format(pkg_name, pkg_rev, result.stderr))

    # 5. Generate BUILD file at repository root
    # Symlink all source files to the root maintaining their module structure
    # e.g., Cli/Basic.lean -> @lean_deps//:Cli/Basic.lean (not @lean_deps//Cli:Cli/Basic.lean)
    all_modules = {}

    for pkg in packages:
        pkg_name = pkg["name"]
        pkg_dir = "{}/{}".format(packages_dir, pkg_name)

        # Find all .lean files and symlink them into the repository root
        lean_files = _find_lean_files(ctx, pkg_dir)
        for lean_file in lean_files:
            rel_path = lean_file.replace(pkg_dir + "/", "")
            # Create directory structure at root level
            dest_dir = "/".join(rel_path.split("/")[:-1])
            if dest_dir:
                ctx.execute(["mkdir", "-p", dest_dir])
            # Symlink the source file to root
            ctx.symlink(lean_file, rel_path)

            # Track module info for BUILD file generation
            module_name = _path_to_module_name(rel_path)
            imports = _parse_imports(ctx, lean_file)
            all_modules[module_name] = {
                "src": rel_path,
                "imports": imports,
                "pkg": pkg_name,
            }

    # Generate single BUILD file at root with all modules
    build_content = _generate_flat_build(all_modules, packages)
    ctx.file("BUILD.bazel", build_content)

def _generate_flat_build(all_modules, packages):
    """Generate a single BUILD.bazel file at repository root with all modules."""
    lines = [
        '# Generated BUILD file for external Lean packages',
        '# DO NOT EDIT - this file is auto-generated',
        '',
        'load("@rules_lean//lean:defs.bzl", "lean_module")',
        '',
        'package(default_visibility = ["//visibility:public"])',
        '',
    ]

    # Add comment about which packages are included
    for pkg in packages:
        lines.append('# Package: {}'.format(pkg["name"]))
    lines.append('')

    # Generate lean_module targets for all modules
    for module_name in sorted(all_modules.keys()):
        info = all_modules[module_name]

        # Filter imports to only include local modules (not stdlib)
        deps = []
        for imp in info["imports"]:
            if _is_stdlib_import(imp):
                continue
            # Check if this import is a module in any of the packages
            if imp in all_modules:
                deps.append(":{}".format(imp))

        lines.append('lean_module(')
        lines.append('    name = "{}",'.format(module_name))
        lines.append('    src = "{}",'.format(info["src"]))
        if deps:
            lines.append('    deps = [')
            for dep in sorted(deps):
                lines.append('        "{}",'.format(dep))
            lines.append('    ],')
        lines.append(')')
        lines.append('')

    return "\n".join(lines)

def _find_lean_files(ctx, dir_path):
    """Find all .lean files in a directory recursively."""
    result = ctx.execute(
        ["find", dir_path, "-name", "*.lean", "-type", "f"],
        timeout = 30,
    )
    if result.return_code != 0:
        return []

    files = []
    for line in result.stdout.strip().split("\n"):
        if line and line.endswith(".lean"):
            # Skip test files for now
            if "/CliTest/" in line or "Test.lean" in line:
                continue
            files.append(line)
    return sorted(files)

def _path_to_module_name(rel_path):
    """Convert a relative path to a Lean module name.

    Examples:
        Cli.lean -> Cli
        Cli/Basic.lean -> Cli.Basic
        Cli/Extensions.lean -> Cli.Extensions
    """
    # Remove .lean extension
    name = rel_path.removesuffix(".lean")
    # Replace path separators with dots
    name = name.replace("/", ".")
    return name

def _parse_imports(ctx, file_path):
    """Parse import statements from a Lean file.

    Returns a list of module names that are imported.
    """
    result = ctx.execute(["cat", file_path], timeout = 10)
    if result.return_code != 0:
        return []

    imports = []
    for line in result.stdout.split("\n"):
        line = line.strip()
        # Skip comments and empty lines
        if not line or line.startswith("--") or line.startswith("/-"):
            continue
        # Match import statements
        if line.startswith("import "):
            # Handle: import Foo, import Foo.Bar, private import Foo
            parts = line.split(" ")
            for i, part in enumerate(parts):
                if part == "import" and i + 1 < len(parts):
                    module = parts[i + 1]
                    # Remove any trailing comments
                    if "--" in module:
                        module = module.split("--")[0].strip()
                    imports.append(module)
                    break
        # Stop at first non-import, non-comment line after seeing imports
        elif imports and not line.startswith("import") and not line.startswith("private"):
            break

    return imports

def _is_stdlib_import(module_name):
    """Check if a module is from the Lean standard library."""
    stdlib_prefixes = ["Init", "Lean", "Std", "Lake"]
    for prefix in stdlib_prefixes:
        if module_name == prefix or module_name.startswith(prefix + "."):
            return True
    return False

lean_deps = repository_rule(
    implementation = _lean_deps_impl,
    attrs = {
        "manifest": attr.label(
            doc = "Path to lake-manifest.json",
            allow_single_file = [".json"],
            mandatory = True,
        ),
        "lakefile": attr.label(
            doc = "Path to lakefile.toml or lakefile.lean",
            allow_single_file = True,
            mandatory = True,
        ),
    },
    environ = ["HOME"],  # Git may need HOME
)
