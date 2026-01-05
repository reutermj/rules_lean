"""Lean toolchain definition."""

LeanToolchainInfo = provider(
    doc = "Information about the Lean toolchain.",
    fields = {
        "lean": "The lean executable",
        "leanc": "The leanc executable",
        "version": "The Lean version string",
    },
)

def _lean_toolchain_impl(ctx):
    toolchain_info = platform_common.ToolchainInfo(
        lean = ctx.executable.lean,
        leanc = ctx.executable.leanc,
        version = ctx.attr.version,
    )
    return [toolchain_info]

lean_toolchain = rule(
    implementation = _lean_toolchain_impl,
    attrs = {
        "lean": attr.label(
            doc = "The lean executable",
            executable = True,
            cfg = "exec",
            mandatory = True,
        ),
        "leanc": attr.label(
            doc = "The leanc executable",
            executable = True,
            cfg = "exec",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The Lean version",
            mandatory = True,
        ),
    },
    provides = [platform_common.ToolchainInfo],
)
