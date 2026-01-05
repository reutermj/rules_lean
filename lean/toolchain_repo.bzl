"""Macro for declaring toolchain targets in a downloaded Lean repository."""

load("//lean:toolchain.bzl", "lean_toolchain")

def declare_lean_toolchain(name, version, platform):
    """Declares all toolchain targets for a downloaded Lean distribution.

    Args:
        name: Base name for the toolchain targets
        version: Lean version string (e.g., "4.12.0")
        platform: Lean platform string (e.g., "linux", "darwin_aarch64")
    """
    lean_path = "lean-{}-{}/bin/lean".format(version, platform)
    leanc_path = "lean-{}-{}/bin/leanc".format(version, platform)

    # Export the raw files for use in toolchain provider
    native.exports_files([lean_path, leanc_path])

    # Aliases for direct invocation: bazel run @...//:lean -- --version
    native.alias(
        name = "lean",
        actual = lean_path,
    )

    native.alias(
        name = "leanc",
        actual = leanc_path,
    )

    lean_toolchain(
        name = "toolchain",
        lean = ":lean",
        leanc = ":leanc",
        version = version,
        visibility = ["//visibility:public"],
    )

    native.toolchain(
        name = "lean_toolchain",
        toolchain = ":toolchain",
        toolchain_type = "@rules_lean//lean:toolchain_type",
        visibility = ["//visibility:public"],
    )
