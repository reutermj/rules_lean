"""Executable rule for updating Lake dependencies."""

def _lake_update_impl(ctx):
    """Implementation of the lake_update rule.

    Generates a script that runs `lake update` to resolve dependency versions
    and update lake-manifest.json. Package downloads happen later during
    `bazel build` via the lean_lake_packages repository rule.
    """
    toolchain = ctx.toolchains["@rules_lean//lean:toolchain_type"]

    # Derive lake path from lean path (they're in the same bin directory)
    lean_path = toolchain.lean.path
    lake_path = lean_path.rsplit("/lean", 1)[0] + "/lake"

    # Generate runner script
    runner = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(
        output = runner,
        content = """#!/bin/bash
set -e
cd "$BUILD_WORKSPACE_DIRECTORY"
{lake} update
echo "lake-manifest.json updated. Run 'bazel build' to download packages."
""".format(lake = lake_path),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = runner,
        runfiles = ctx.runfiles(files = [toolchain.lean]),
    )]

lake_update = rule(
    implementation = _lake_update_impl,
    doc = """Updates lake-manifest.json by running `lake update`.

This rule resolves dependency versions from lakefile.toml and writes
the pinned versions to lake-manifest.json. Package downloads happen
during `bazel build` when the @lake repository rule fetches.

Usage:
    lake_update(name = "lake_update")

Run with: bazel run //:lake_update
""",
    executable = True,
    toolchains = ["@rules_lean//lean:toolchain_type"],
)
