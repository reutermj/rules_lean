# Gazelle for Lean

This document introduces Gazelle support in `rules_lean` for automatically generating BUILD files from Lean source code.

## Overview

Gazelle is a BUILD file generator that scans your source code and generates Bazel BUILD files with correct dependencies. The `rules_lean` Gazelle extension discovers `.lean` files and generates `lean_module` targets for each one.

## Why Gazelle?

The Lean compiler does not support batch compilation of multiple `.lean` files to multiple `.c` files in a single invocation. Lake (Lean's build system) handles build ordering by parsing imports, building a dependency graph, and orchestrating compilation.

In Bazel, action graphs must be declared at **analysis time** (before any actions run). Gazelle bridges this gap by:

1. Running before the build to discover `.lean` files
2. Using Lean's tooling to extract imports
3. Generating BUILD files with explicit dependencies

This gives you:

- **Fine-grained caching**: Each file is a separate build action
- **Explicit dependency graph**: Bazel sees the full graph at analysis time
- **Parallel builds**: Independent modules build in parallel automatically
- **Lean semantics**: One module = one file = one target

## Quick Start

### 1. Add Dependencies

In your `MODULE.bazel`:

```python
bazel_dep(name = "rules_lean")
bazel_dep(name = "gazelle", version = "0.47.0")
bazel_dep(name = "rules_go", version = "0.59.0")

# Configure Lean toolchain
lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(version = "4.26.0")
use_repo(lean, "lean_toolchain_linux_x86_64")
register_toolchains("@lean_toolchain_linux_x86_64//:lean_toolchain")

# Go SDK for Gazelle
go_sdk = use_extension("@rules_go//go:extensions.bzl", "go_sdk")
go_sdk.download(version = "1.25.6")
```

### 2. Create Gazelle Target

In your root `BUILD.bazel`:

```python
load("@gazelle//:def.bzl", "gazelle")

gazelle(
    name = "gazelle",
    gazelle = "@rules_lean//gazelle:gazelle_bin",
)
```

### 3. Run Gazelle

```bash
# Generate BUILD files for the entire workspace
bazel run //:gazelle

# Generate for a specific directory
bazel run //:gazelle -- path/to/dir
```

## What Gets Generated

For each `.lean` file, Gazelle generates a `lean_module` target:

**Source structure:**
```
MyLib/
├── Core.lean
└── Utils.lean
```

**Generated BUILD.bazel:**
```python
load("@rules_lean//lean:defs.bzl", "lean_module")

lean_module(
    name = "MyLib.Core",
    src = "Core.lean",
)

lean_module(
    name = "MyLib.Utils",
    src = "Utils.lean",
)
```

The target name follows Lean's module naming convention: the file path with slashes replaced by dots.

## Directives

Gazelle directives are special comments in BUILD files that control generation behavior:

### `lean_root`

Sets the module name prefix to strip from paths:

```python
# gazelle:lean_root src
```

With this directive, `src/MyLib/Core.lean` becomes target `MyLib.Core` instead of `src.MyLib.Core`.

### `lean_exclude`

Excludes files matching a pattern:

```python
# gazelle:lean_exclude test/**
# gazelle:lean_exclude *_backup.lean
```

## Manual Overrides

Gazelle respects `# keep` comments to preserve manual edits:

```python
lean_module(
    name = "MyModule",
    src = "MyModule.lean",
    deps = [
        ":AutoDetected",
        ":ManuallyAdded",  # keep
    ],
)
```

Lines with `# keep` are preserved when Gazelle updates the file.

## Current Limitations

The Gazelle extension is in active development. Current status:

| Feature | Status |
|---------|--------|
| File discovery | Implemented |
| Module naming | Implemented |
| `lean_root` directive | Implemented |
| `lean_exclude` directive | Implemented |
| Import extraction | Planned (Phase G2) |
| Local dependency resolution | Planned (Phase G3) |
| External dependencies | Planned (Phase G4) |
| Binary detection | Planned (Phase G5) |

Currently, `deps` attributes are not automatically populated. You need to add dependencies manually until Phase G3 is complete.

## How It Works

The Gazelle extension implements Bazel's Gazelle language interface:

1. **Discovery**: Scans directories for `.lean` files
2. **Generation**: Creates a `lean_module` target for each file
3. **Resolution**: Maps imports to Bazel labels (planned)
4. **Merging**: Updates existing BUILD files, respecting `# keep` comments

The extension source code is at [gazelle/](../gazelle/).

## Example Project

See [examples/03_gazelle_basic/](../examples/03_gazelle_basic/) for a working example:

```bash
cd examples/03_gazelle_basic
bazel run //:gazelle
bazel build //...
```

## Further Reading

- [Gazelle Design Document](gazelle-design.md) - Detailed technical design
- [Bazel Gazelle Documentation](https://github.com/bazelbuild/bazel-gazelle)
