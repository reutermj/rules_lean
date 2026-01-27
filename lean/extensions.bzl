"""Bzlmod extensions for Lean toolchains."""

load("//lean:repositories.bzl", "lean_download")
load("//lean/private:lake_packages.bzl", "lean_lake_packages")
load("//lean/private:project.bzl", "lean_project")

# Mapping from Bazel platform identifiers to Lean release platform strings
_LEAN_PLATFORMS = {
    "linux-x86_64": "linux",
    "linux-aarch64": "linux_aarch64",
    "macos-x86_64": "darwin",
    "macos-aarch64": "darwin_aarch64",
    "windows-x86_64": "windows",
}

# Reverse mapping for constructing paths inside downloaded toolchains
_BAZEL_TO_LEAN_PLATFORM = {
    "linux_x86_64": "linux",
    "linux_aarch64": "linux_aarch64",
    "macos_x86_64": "darwin",
    "macos_aarch64": "darwin_aarch64",
    "windows_x86_64": "windows",
}

def _detect_host_platform(os):
    """Detect the host platform from module_ctx.os.

    Args:
        os: The os object from module_ctx

    Returns:
        Bazel platform identifier (e.g., "linux_x86_64")
    """
    if os.name == "linux":
        if os.arch == "amd64" or os.arch == "x86_64":
            return "linux_x86_64"
        elif os.arch == "aarch64" or os.arch == "arm64":
            return "linux_aarch64"
    elif os.name == "mac os x" or os.name.startswith("darwin"):
        if os.arch == "amd64" or os.arch == "x86_64":
            return "macos_x86_64"
        elif os.arch == "aarch64" or os.arch == "arm64":
            return "macos_aarch64"
    elif os.name.startswith("windows"):
        return "windows_x86_64"
    fail("Unsupported host platform: {} {}".format(os.name, os.arch))

def _toolchain_impl(ctx):
    version = None

    # First pass: process toolchain tags and download all platform toolchains
    for mod in ctx.modules:
        for toolchain in mod.tags.toolchain:
            version = toolchain.version
            for bazel_platform, lean_platform in _LEAN_PLATFORMS.items():
                name = "lean_toolchain_{}".format(bazel_platform.replace("-", "_"))
                lean_download(
                    name = name,
                    version = version,
                    platform = lean_platform,
                    sha256 = "",
                )

    # Detect host platform for project repository rules
    host_platform = _detect_host_platform(ctx.os)
    host_toolchain_repo = "lean_toolchain_{}".format(host_platform)
    host_lean_platform = _BAZEL_TO_LEAN_PLATFORM[host_platform]

    # Construct path to lean binary in the host toolchain repository
    lean_binary_path = None
    if version:
        lean_binary_path = "@{repo}//:lean-{version}-{platform}/bin/lean".format(
            repo = host_toolchain_repo,
            version = version,
            platform = host_lean_platform,
        )

    # Process from_lake tags to create @lake repository
    for mod in ctx.modules:
        for lake_tag in mod.tags.from_lake:
            if not version:
                fail("lean.from_lake requires lean.toolchain to be specified first")

            # Read lake-manifest.json to get package information
            manifest_path = ctx.path(Label("@@//:" + lake_tag.manifest))
            manifest_content = ctx.read(manifest_path)
            manifest = json.decode(manifest_content)

            packages_dir = manifest.get("packagesDir", ".lake/packages")

            # Collect all packages from manifest
            packages = {}
            for pkg in manifest.get("packages", []):
                pkg_name = pkg.get("name")
                if pkg_name:
                    packages[pkg_name] = packages_dir + "/" + pkg_name

            # Create @lake repository with all packages
            if packages:
                lean_lake_packages(
                    name = "lake",
                    packages = packages,
                    lean_binary = lean_binary_path,
                )

    # Process project tags
    for mod in ctx.modules:
        for project in mod.tags.project:
            if not version:
                fail("lean.project requires lean.toolchain to be specified first")

            lean_project(
                name = project.name,
                root = project.root,
                lean_binary = lean_binary_path,
                deps = project.deps,
            )

_toolchain_tag = tag_class(
    attrs = {
        "version": attr.string(mandatory = True),
    },
)

_project_tag = tag_class(
    attrs = {
        "name": attr.string(mandatory = True),
        "root": attr.string(default = ""),
        "deps": attr.string_list(default = []),
    },
)

_from_lake_tag = tag_class(
    attrs = {
        "manifest": attr.string(default = "lake-manifest.json"),
    },
)

lean = module_extension(
    implementation = _toolchain_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
        "project": _project_tag,
        "from_lake": _from_lake_tag,
    },
)
