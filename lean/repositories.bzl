"""Repository rules for downloading Lean toolchains."""

_LEAN_PLATFORMS = {
    "linux-x86_64": "linux",
    "linux-aarch64": "linux_aarch64",
    "macos-x86_64": "darwin",
    "macos-aarch64": "darwin_aarch64",
    "windows-x86_64": "windows",
}

def _lean_download_impl(ctx):
    version = ctx.attr.version
    platform = ctx.attr.platform

    url = "https://github.com/leanprover/lean4/releases/download/v{version}/lean-{version}-{platform}.tar.zst".format(
        version = version,
        platform = platform,
    )

    download_kwargs = {"url": url}
    if ctx.attr.sha256:
        download_kwargs["sha256"] = ctx.attr.sha256

    ctx.download_and_extract(**download_kwargs)

    # Create BUILD file that invokes the macro
    ctx.file("BUILD.bazel", """
load("@rules_lean//lean:toolchain_repo.bzl", "declare_lean_toolchain")

declare_lean_toolchain(
    name = "lean",
    version = "{version}",
    platform = "{platform}",
)
""".format(version = version, platform = platform))

lean_download = repository_rule(
    implementation = _lean_download_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
        "sha256": attr.string(),
    },
)

def lean_register_toolchains(name = "lean_toolchain", version = None, sha256s = {}):
    """Register Lean toolchains for all supported platforms.

    Args:
        name: Base name for the toolchain repositories (default: "lean_toolchain")
        version: The Lean version to download (e.g., "4.12.0")
        sha256s: Optional dict of platform -> sha256 for integrity checking
    """
    if not version:
        fail("version is required")

    for bazel_platform, lean_platform in _LEAN_PLATFORMS.items():
        repo_name = "{}_{}".format(name, bazel_platform.replace("-", "_"))
        lean_download(
            name = repo_name,
            version = version,
            platform = lean_platform,
            sha256 = sha256s.get(lean_platform, ""),
        )
        native.register_toolchains("@{}//:lean_toolchain".format(repo_name))
