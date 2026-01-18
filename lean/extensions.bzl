"""Bzlmod extensions for Lean toolchains and dependencies."""

load("//lean:repositories.bzl", "lean_download")
load("//lean/private:deps.bzl", "lean_deps")

_LEAN_PLATFORMS = {
    "linux-x86_64": "linux",
    "linux-aarch64": "linux_aarch64",
    "macos-x86_64": "darwin",
    "macos-aarch64": "darwin_aarch64",
    "windows-x86_64": "windows",
}

def _lean_impl(ctx):
    # Handle toolchain tags
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

    # Handle deps tags
    for mod in ctx.modules:
        for deps in mod.tags.deps:
            lean_deps(
                name = deps.name,
                manifest = deps.manifest,
                lakefile = deps.lakefile,
            )

_toolchain_tag = tag_class(
    attrs = {
        "version": attr.string(mandatory = True),
    },
)

_deps_tag = tag_class(
    attrs = {
        "name": attr.string(mandatory = True),
        "manifest": attr.label(
            mandatory = True,
            allow_single_file = [".json"],
            doc = "Path to lake-manifest.json",
        ),
        "lakefile": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "Path to lakefile.toml or lakefile.lean",
        ),
    },
)

lean = module_extension(
    implementation = _lean_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
        "deps": _deps_tag,
    },
)
