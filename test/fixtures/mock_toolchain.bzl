"""Mock toolchain for testing lean rules without downloading the real toolchain."""

load("//lean:toolchain.bzl", "lean_toolchain")

def declare_mock_toolchain(name):
    """Creates a mock Lean toolchain for testing purposes.

    Args:
        name: Base name for the toolchain targets.
    """

    # Create mock executable files
    native.genrule(
        name = name + "_mock_lean_gen",
        outs = [name + "_mock_lean"],
        cmd = "echo '#!/bin/bash\necho mock lean\ntouch $$2' > $@ && chmod +x $@",
        executable = True,
    )

    native.genrule(
        name = name + "_mock_leanc_gen",
        outs = [name + "_mock_leanc"],
        cmd = "echo '#!/bin/bash\necho mock leanc\ntouch $$2' > $@ && chmod +x $@",
        executable = True,
    )

    native.genrule(
        name = name + "_mock_lake_gen",
        outs = [name + "_mock_lake"],
        cmd = "echo '#!/bin/bash\necho mock lake' > $@ && chmod +x $@",
        executable = True,
    )

    # Empty filegroup for mock headers
    native.filegroup(
        name = name + "_mock_headers",
        srcs = [],
    )

    # Empty filegroup for mock libs
    native.filegroup(
        name = name + "_mock_libs",
        srcs = [],
    )

    lean_toolchain(
        name = name + "_toolchain",
        lean = name + "_mock_lean",
        leanc = name + "_mock_leanc",
        lake = name + "_mock_lake",
        version = "4.12.0-mock",
        headers = name + "_mock_headers",
        libs = name + "_mock_libs",
        visibility = ["//visibility:public"],
    )

    native.toolchain(
        name = name,
        toolchain = name + "_toolchain",
        toolchain_type = "//lean:toolchain_type",
        visibility = ["//visibility:public"],
    )
