"""Lean toolchain definition."""

LeanToolchainInfo = provider(
    doc = "Information about the Lean toolchain.",
    fields = {
        "lean": "The lean executable File",
        "leanc": "The leanc executable File",
        "lake": "The lake executable File",
        "version": "The Lean version string",
        "lean_include": "Directory containing Lean headers (include/)",
        "lean_lib": "Directory containing Lean runtime libraries (lib/lean/)",
        "support_lib": "Directory containing support libraries like libc++ (lib/)",
        "headers": "depset of Lean header files",
        "libs": "depset of Lean library files (.a)",
    },
)

def _lean_toolchain_impl(ctx):
    # Derive the external repository root from the lean executable path.
    # lean.path is like "external/lean_toolchain_.../lean-4.12.0-linux/bin/lean"
    # We extract "external/lean_toolchain_.../lean-4.12.0-linux" as the dist root.
    lean_path = ctx.file.lean.path

    # Remove "/bin/lean" suffix to get dist_dir
    dist_dir = lean_path.rsplit("/bin/lean", 1)[0]

    toolchain_info = platform_common.ToolchainInfo(
        lean = ctx.file.lean,
        leanc = ctx.file.leanc,
        lake = ctx.file.lake,
        version = ctx.attr.version,
        # Lean code does #include <lean/lean.h>, so include path should be to "include/"
        lean_include = dist_dir + "/include",
        lean_lib = dist_dir + "/lib/lean",
        support_lib = dist_dir + "/lib",
        headers = depset(ctx.files.headers),
        libs = depset(ctx.files.libs),
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
        "lake": attr.label(
            doc = "The lake executable file",
            allow_single_file = True,
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The Lean version",
            mandatory = True,
        ),
        "headers": attr.label(
            doc = "Filegroup containing Lean header files",
            mandatory = True,
        ),
        "libs": attr.label(
            doc = "Filegroup containing Lean library files (.a)",
            mandatory = True,
        ),
    },
    provides = [platform_common.ToolchainInfo],
)
