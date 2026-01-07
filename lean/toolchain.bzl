"""Lean toolchain definition."""

LeanToolchainInfo = provider(
    doc = "Information about the Lean toolchain.",
    fields = {
        "lean": "The lean executable File",
        "leanc": "The leanc executable File",
        "version": "The Lean version string",
    },
)

def _lean_toolchain_impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        lean = ctx.file.lean,
        leanc = ctx.file.leanc,
        version = ctx.attr.version,
    )
    return [toolchain_info]

lean_toolchain = rule(
    implementation = _lean_toolchain_impl,
    attrs = {
        "lean": attr.label(
            doc = "The lean executable file",
            allow_single_file = True,
            mandatory = True,
        ),
        "leanc": attr.label(
            doc = "The leanc executable file",
            allow_single_file = True,
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The Lean version",
            mandatory = True,
        ),
    },
    provides = [platform_common.ToolchainInfo],
)
