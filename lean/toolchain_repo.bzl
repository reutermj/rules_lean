"""Macro for declaring toolchain targets in a downloaded Lean repository."""

load("//lean:toolchain.bzl", "lean_toolchain")

def declare_lean_toolchain(name, version, platform):
    """Declares all toolchain targets for a downloaded Lean distribution.

    Args:
        name: Base name for the toolchain targets
        version: Lean version string (e.g., "4.12.0")
        platform: Lean platform string (e.g., "linux", "darwin_aarch64")
    """
    dist_dir = "lean-{}-{}".format(version, platform)
    lean_path = "{}/bin/lean".format(dist_dir)
    leanc_path = "{}/bin/leanc".format(dist_dir)
    lake_path = "{}/bin/lake".format(dist_dir)

    # Export the raw files for use in toolchain provider
    native.exports_files([lean_path, leanc_path, lake_path])

    # Create filegroup for Lean headers (needed for cc_common.compile inputs)
    native.filegroup(
        name = "lean_headers",
        srcs = native.glob(["{}/include/**".format(dist_dir)]),
    )

    # Create filegroup for Lean libraries (needed for cc_common.link inputs)
    # Includes Lean runtime libs (lib/lean/*.a) and support libs (lib/*.a)
    native.filegroup(
        name = "lean_libs",
        srcs = native.glob([
            "{}/lib/lean/*.a".format(dist_dir),
            "{}/lib/*.a".format(dist_dir),
        ]),
    )

    # Aliases for direct invocation: bazel run @...//:lean -- --version
    native.alias(
        name = "lean",
        actual = lean_path,
    )

    native.alias(
        name = "leanc",
        actual = leanc_path,
    )

    native.alias(
        name = "lake",
        actual = lake_path,
    )

    lean_toolchain(
        name = "toolchain",
        lean = ":lean",
        leanc = ":leanc",
        lake = ":lake",
        version = version,
        headers = ":lean_headers",
        libs = ":lean_libs",
        visibility = ["//visibility:public"],
    )

    native.toolchain(
        name = "lean_toolchain",
        toolchain = ":toolchain",
        toolchain_type = "@rules_lean//lean:toolchain_type",
        visibility = ["//visibility:public"],
    )
