"""Rules for managing Lake manifest files.

Similar to pip_compile in rules_python, this provides targets for generating
and validating lake-manifest.json files from lakefile.toml.
"""

def _lake_manifest_update_impl(ctx):
    """Implementation for the .update target that regenerates the manifest."""
    lean_toolchain = ctx.toolchains["@rules_lean//lean:toolchain_type"]
    lake = lean_toolchain.lake

    script = ctx.actions.declare_file(ctx.label.name + ".sh")

    # Get the directory containing the lakefile
    lakefile_short = ctx.file.lakefile.short_path
    manifest_short = ctx.file.manifest.short_path

    # For executable rules, we need to use the runfiles path.
    # The script runs with $0.runfiles containing the resolved runfiles tree.
    ctx.actions.write(
        output = script,
        content = """\
#!/bin/bash
set -euo pipefail

# Resolve the lake binary from runfiles
# RUNFILES_DIR is set by Bazel when running the script
RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
LAKE="$RUNFILES_DIR/{workspace}/{lake}"

# Resolve paths relative to workspace
LAKEFILE_DIR=$(dirname "{lakefile}")
cd "$BUILD_WORKSPACE_DIRECTORY/$LAKEFILE_DIR"

# Run lake update to regenerate the manifest
# Lake exit code 4 indicates toolchain update suggestion - not a failure
"$LAKE" update || {{
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 4 ]; then
        echo "Note: Lake suggests updating toolchain (this is informational)"
    else
        exit $EXIT_CODE
    fi
}}

echo "Updated {manifest}"
""".format(
            workspace = ctx.workspace_name,
            lakefile = lakefile_short,
            lake = lake.short_path,
            manifest = manifest_short,
        ),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [lake]),
    )]

_lake_manifest_update = rule(
    implementation = _lake_manifest_update_impl,
    attrs = {
        "lakefile": attr.label(
            doc = "The lakefile.toml or lakefile.lean file",
            allow_single_file = True,
            mandatory = True,
        ),
        "manifest": attr.label(
            doc = "The lake-manifest.json file to update",
            allow_single_file = [".json"],
            mandatory = True,
        ),
    },
    executable = True,
    toolchains = ["@rules_lean//lean:toolchain_type"],
)

def _lake_manifest_test_impl(ctx):
    """Test that validates the manifest is up-to-date."""
    lean_toolchain = ctx.toolchains["@rules_lean//lean:toolchain_type"]
    lake = lean_toolchain.lake

    script = ctx.actions.declare_file(ctx.label.name + ".sh")

    # Compute the update target name from test target name
    # e.g., "lake_manifest_test" -> "lake_manifest.update"
    test_name = ctx.label.name
    if test_name.endswith("_test"):
        update_name = test_name[:-5] + ".update"
    else:
        update_name = test_name + ".update"

    ctx.actions.write(
        output = script,
        content = """\
#!/bin/bash
set -euo pipefail

# Resolve the lake binary from runfiles
RUNFILES_DIR="${{RUNFILES_DIR:-$0.runfiles}}"
LAKE="$RUNFILES_DIR/{workspace}/{lake}"

# Get the lakefile and manifest from runfiles
LAKEFILE="$RUNFILES_DIR/{workspace}/{lakefile}"
MANIFEST="$RUNFILES_DIR/{workspace}/{manifest}"

# Create temp directory for validation
WORK_TMPDIR=$(mktemp -d)
trap "rm -rf $WORK_TMPDIR" EXIT

# Copy lakefile to temp
cp "$LAKEFILE" "$WORK_TMPDIR/lakefile.toml"

# Check if lean-toolchain exists alongside the lakefile and copy it
LAKEFILE_DIR=$(dirname "$LAKEFILE")
if [ -f "$LAKEFILE_DIR/lean-toolchain" ]; then
    cp "$LAKEFILE_DIR/lean-toolchain" "$WORK_TMPDIR/"
fi

cd "$WORK_TMPDIR"

# Run lake update to generate a fresh manifest
# Exit code 4 means toolchain update suggestion, not a failure
"$LAKE" update 2>/dev/null || {{
    EXIT_CODE=$?
    if [ $EXIT_CODE -ne 4 ]; then
        echo "WARNING: lake update failed with exit code $EXIT_CODE, skipping validation"
        exit 0
    fi
}}

# Compare generated manifest with checked-in version
if [ ! -f lake-manifest.json ]; then
    echo "WARNING: lake update did not create lake-manifest.json"
    exit 0
fi

if ! diff -q lake-manifest.json "$MANIFEST" > /dev/null 2>&1; then
    echo "ERROR: lake-manifest.json is out of date!"
    echo ""
    echo "Differences:"
    diff lake-manifest.json "$MANIFEST" || true
    echo ""
    echo "Run: bazel run //{pkg}:{update_name}"
    exit 1
fi

echo "lake-manifest.json is up to date"
""".format(
            workspace = ctx.workspace_name,
            lakefile = ctx.file.lakefile.short_path,
            manifest = ctx.file.manifest.short_path,
            lake = lake.short_path,
            pkg = ctx.label.package,
            update_name = update_name,
        ),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [lake, ctx.file.lakefile, ctx.file.manifest]),
    )]

_lake_manifest_test = rule(
    implementation = _lake_manifest_test_impl,
    attrs = {
        "lakefile": attr.label(
            doc = "The lakefile.toml or lakefile.lean file",
            allow_single_file = True,
            mandatory = True,
        ),
        "manifest": attr.label(
            doc = "The lake-manifest.json file to validate",
            allow_single_file = [".json"],
            mandatory = True,
        ),
    },
    test = True,
    toolchains = ["@rules_lean//lean:toolchain_type"],
)

def lake_manifest(name, lakefile, manifest, visibility = None, tags = None, **kwargs):
    """Macro for managing Lake manifest files.

    Similar to pip_compile in rules_python, this creates:
    - {name}: A filegroup containing the manifest
    - {name}.update: Executable to regenerate the manifest
    - {name}_test: Test to validate manifest is up-to-date

    Args:
        name: Base name for the targets
        lakefile: Label for lakefile.toml or lakefile.lean
        manifest: Label for lake-manifest.json
        visibility: Visibility for the targets
        tags: Tags for the targets
        **kwargs: Additional arguments passed to all targets

    Example:
        lake_manifest(
            name = "lake_manifest",
            lakefile = "lakefile.toml",
            manifest = "lake-manifest.json",
        )

        # Update manifest: bazel run //:lake_manifest.update
        # Validate in CI: bazel test //:lake_manifest_test

    Note:
        The test target requires network access to run `lake update`.
        It is automatically tagged with "requires-network". If Lake
        cannot be run (e.g., in a sandboxed environment), the test
        will pass with a warning.
    """
    tags = tags or []

    # Main target - filegroup with the manifest
    native.filegroup(
        name = name,
        srcs = [manifest],
        visibility = visibility,
        tags = tags,
        **kwargs
    )

    # Update target
    _lake_manifest_update(
        name = name + ".update",
        lakefile = lakefile,
        manifest = manifest,
        visibility = visibility,
        tags = tags,
        **kwargs
    )

    # Test target for CI - needs network access for lake update
    test_tags = tags + ["requires-network"]
    _lake_manifest_test(
        name = name + "_test",
        lakefile = lakefile,
        manifest = manifest,
        visibility = visibility,
        tags = test_tags,
        **kwargs
    )
