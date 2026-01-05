"""Bzlmod extensions for Lean toolchains."""

load("//lean:repositories.bzl", "lean_download")

_LEAN_PLATFORMS = {
    "linux-x86_64": "linux",
    "linux-aarch64": "linux_aarch64",
    "macos-x86_64": "darwin",
    "macos-aarch64": "darwin_aarch64",
    "windows-x86_64": "windows",
}

def _toolchain_impl(ctx):
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

_toolchain_tag = tag_class(
    attrs = {
        "version": attr.string(mandatory = True),
    },
)

lean = module_extension(
    implementation = _toolchain_impl,
    tag_classes = {
        "toolchain": _toolchain_tag,
    },
)
