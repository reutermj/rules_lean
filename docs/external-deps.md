# External Dependencies

This document describes how `rules_lean` integrates external Lean packages (Lake dependencies) into Bazel builds.

## Overview

Lean projects commonly depend on external packages managed by Lake. To support these in Bazel, we need to:

1. Provide a way to download external packages using Lake
2. Generate `lean_module` targets for each module in the dependency
3. Wire dependencies between modules and across packages

---

## User Experience

### Workflow

1. Create a `lakefile.toml` declaring dependencies
2. Run `bazel run //:lake_update` to resolve versions and generate `lake-manifest.json`
3. Build with `bazel build //...` (packages are downloaded and built automatically)

The `lake_update` rule is similar to `pip_compile` in `rules_python`—it updates the lockfile that Bazel reads. Package downloads happen during `bazel build` via the repository rule.

### Configuration

```python
# MODULE.bazel
bazel_dep(name = "rules_lean", version = "0.1.0")

lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(version = "4.27.0")

# Creates @lake repository containing all packages from manifest
# Each package becomes a target: @lake//:Cli, @lake//:Std, etc.
lean.from_lake(
    manifest = "lake-manifest.json",
)

# Project with external dependencies
lean.project(
    name = "myapp",
    root = "src",
    deps = ["@lake//:Cli"],  # Reference package from @lake repo
)

use_repo(lean, "lean_toolchain_linux_x86_64", "myapp", "lake")
```

The `lean.from_lake()` tag:
1. Reads `lake-manifest.json` to find all packages and their locations
2. Creates a single `@lake` repository with `lean_module` targets for all packages
3. Each package's modules are available as `@lake//:PackageName` and `@lake//:PackageName.SubModule`

The `lean.project()` tag's `deps` attribute references packages from the `@lake` repository.

### BUILD.bazel

```python
# BUILD.bazel
load("@rules_lean//lean:defs.bzl", "lake_update", "lean_binary")

# Rule to update Lake dependencies
# Run with: bazel run //:lake_update
lake_update(name = "lake_update")

lean_binary(
    name = "app",
    src = "src/Main.lean",
    deps = ["@myapp//:Main"],  # Reference module from lean.project
)
```

### Lakefile Configuration

The user's project must have a `lakefile.toml` or `lakefile.lean` declaring dependencies:

```toml
# lakefile.toml
name = "myapp"
version = "0.1.0"

[[require]]
name = "Cli"
git = "https://github.com/leanprover/lean4-cli"
rev = "v4.27.0"

[[lean_lib]]
name = "MyApp"
```

### Updating Dependencies

When you add or change dependencies in `lakefile.toml`, run:

```bash
bazel run //:lake_update
```

This executes Lake to:
1. Resolve dependency versions from `lakefile.toml`
2. Generate/update `lake-manifest.json` with exact revisions

The `lake-manifest.json` should be checked into version control (like a lockfile).

Note: Packages are downloaded later during `bazel build`, not during `lake_update`.

---

## Architecture

### Two-Phase Workflow

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Phase 1: Update Manifest                         │
│                        (bazel run //:lake_update)                    │
│                                                                      │
│  1. Execute `lake update` with user's lakefile.toml                 │
│  2. Lake resolves dependency versions                                │
│  3. Lake generates lake-manifest.json with pinned revisions          │
│  4. User commits lake-manifest.json to version control               │
│  (Note: packages are NOT downloaded yet)                             │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                     Phase 2: Build                                   │
│                        (bazel build //...)                           │
│                                                                      │
│  MODULE.bazel: lean.from_lake(), lean.project(deps = ["@lake//:Cli"])│
│                                                                      │
│                              │                                       │
│                              ▼                                       │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │              Module Extension (loading phase)                  │  │
│  │                                                                │  │
│  │  1. Read lake-manifest.json for all package metadata          │  │
│  │  2. Create lean_lake_packages repo rule for @lake             │  │
│  │  3. Create lean_project repo rule for @myapp                   │  │
│  └────────────────────────────┬──────────────────────────────────┘  │
│                               │                                      │
│               ┌───────────────┴───────────────┐                      │
│               ▼                               ▼                      │
│  ┌─────────────────────────┐    ┌─────────────────────────┐         │
│  │ @lake repo rule         │    │ @myapp repo rule        │         │
│  │                         │    │                         │         │
│  │ 1. Run `lake update`    │    │ 1. Glob .lean files     │         │
│  │    to download pkgs     │    │ 2. Parse imports        │         │
│  │ 2. Parse imports        │    │ 3. Generate BUILD       │         │
│  │ 3. Generate BUILD       │    │    with @lake deps      │         │
│  └─────────────────────────┘    └─────────────────────────┘         │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Lake Packages Repository Rule

The `lean_lake_packages` repository rule creates the `@lake` repository:

1. **Downloads packages**: Runs `lake update` to clone packages to `.lake/packages/`
2. **Discovers modules**: Globs for `.lean` files in each package's library directories
3. **Parses imports**: Extracts `import` statements to build dependency graph
4. **Generates BUILD file**: Creates `lean_module` targets for all packages with resolved deps

Note: Package downloads happen during Bazel's fetch phase (when the repo rule executes), not during `bazel run //:lake_update`. The `lake_update` rule only updates `lake-manifest.json`.

### The lake_update Rule

The `lake_update` rule is an executable Bazel rule that:

1. Invokes `lake update` in the workspace directory
2. Resolves dependency versions from `lakefile.toml`
3. Generates/updates `lake-manifest.json` with pinned revisions

```python
lake_update(
    name = "lake_update",
)
```

Run with `bazel run //:lake_update` whenever dependencies change in `lakefile.toml`.

Note: This rule only updates the manifest file. Package downloads happen later during `bazel build` when the `@lake` repository rule fetches.

### Import Parsing Strategy

We use Lean's built-in `--deps` flag to discover imports:

```bash
$ lean --deps Cli.lean
/path/to/lean/lib/lean/Init.olean
/path/to/project/Cli/Basic.olean
```

This outputs expected `.olean` paths for all imports. The repository rule:
1. Sets `LEAN_PATH` to include all package directories
2. Runs `lean --deps` on each `.lean` file
3. Filters paths to identify local dependencies vs stdlib

This is the same approach used by `lean_project` for user code (see `docs/repo-rule-dep-resolution.md`).

### Module Name Resolution

Module names are derived from file paths relative to the package root:

| File Path | Module Name |
|-----------|-------------|
| `Cli.lean` | `Cli` |
| `Cli/Basic.lean` | `Cli.Basic` |
| `Cli/Extensions.lean` | `Cli.Extensions` |

When resolving an import like `import Cli.Basic`:
1. Check if it's a local module (in the same package)
2. Check if it's from a dependency package
3. Check if it's a stdlib module (handled by toolchain)

---

## Lean 4 Module System and the `isModule` Flag

### Background

Lean 4 introduced a new module system that changes how definitions are exported from a module. This is controlled by the `isModule` flag in Lean's compilation setup.

### Two Modes of Operation

| Mode | `isModule` | Export Behavior | When to Use |
|------|------------|-----------------|-------------|
| **Traditional** | `false` | All non-`private` definitions exported | User application code |
| **Module System** | `true` | Only `public` definitions exported | External packages using `module` keyword |

### How It Works

When Lean compiles a file, it checks the `isModule` flag to determine visibility:

```
isModule = false:
  - All definitions are exported unless marked `private`
  - No .ir, .olean.private, .olean.server files generated
  - Simpler behavior, suitable for application code

isModule = true:
  - Only definitions in `public section` or marked `public` are exported
  - Generates additional files: .ir, .olean.private, .olean.server
  - Required for packages using Lean 4's `module` keyword
```

The key logic in Lean's compiler (from `DeclModifiers.lean`):
```lean
-- Simplified: if not a module system file, treat non-private as public
def Visibility.isInferredPublic (env : Environment) (v : Visibility) : Bool :=
  if env.isExporting || !env.header.isModule then
    !v.isPrivate
  else
    v.isPublic
```

### Why External Packages Need `isModule = true`

External Lean packages (like `Cli`) use the Lean 4 module system:

```lean
-- Cli/Basic.lean (external package)
module  -- Uses module keyword

public section
  def parseArgs ... -- Explicitly public
end

private def helper ... -- Internal only
```

These packages:
1. Use the `module` keyword at the top of files
2. Use `public section` to explicitly mark exported definitions
3. Generate `.ir` files needed for linking

Without `isModule = true`, Lean doesn't generate the `.ir` files, causing "missing data file for module" errors at link time.

### Why User Code Uses `isModule = false`

Most user application code doesn't use the module system:

```lean
-- src/Utils/Math.lean (user code)
def double (n : Nat) : Nat := n * 2  -- Auto-exported (no `public` needed)
def square (n : Nat) : Nat := n * n  -- Auto-exported
private def helper ... -- Not exported
```

With `isModule = false`:
- All definitions except `private` ones are automatically exported
- No need to wrap code in `public section`
- Simpler, more intuitive behavior

If user code is compiled with `isModule = true` by mistake, definitions won't be visible to importers (causing "unknown identifier" errors) unless wrapped in `public section`.

### How rules_lean Handles This

The `lean_module` rule has an `is_module` attribute:

```python
lean_module(
    name = "Utils.Math",
    src = "Utils/Math.lean",
    is_module = False,  # Default: traditional export behavior
)
```

- **`lean_project` repository rule**: Generates modules with `is_module = False` (default)
- **`lean_lake_packages` repository rule**: Generates modules with `is_module = True` for external packages

This ensures:
- External packages (using Lean 4 module system) compile correctly with `.ir` files
- User code exports all non-private definitions without requiring `public section`

### Common Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| `unknown identifier 'Foo.bar'` | User module compiled with `isModule = true` but no `public section` | Ensure user modules use `is_module = False` |
| `missing data file for module Cli` | External package compiled with `isModule = false` | Ensure external packages use `is_module = True` |

---

## Generated BUILD Files

### Lake Repository (@lake)

The `@lake` repository contains all external packages:

```python
# @lake//:BUILD.bazel (auto-generated)
load("@rules_lean//lean:defs.bzl", "lean_module")

# Cli package modules
lean_module(
    name = "Cli.Basic",
    src = "Cli/Cli/Basic.lean",
    deps = [],  # Only stdlib imports
    visibility = ["//visibility:public"],
)

lean_module(
    name = "Cli.Extensions",
    src = "Cli/Cli/Extensions.lean",
    deps = [":Cli.Basic"],
    visibility = ["//visibility:public"],
)

lean_module(
    name = "Cli",
    src = "Cli/Cli.lean",
    deps = [":Cli.Basic", ":Cli.Extensions"],
    visibility = ["//visibility:public"],
)

# Other packages (Std, etc.) would also be here...
```

### User Project (@myapp)

```python
# @myapp//:BUILD.bazel (auto-generated)
load("@rules_lean//lean:defs.bzl", "lean_module")

lean_module(
    name = "MyApp.Utils",
    src = "MyApp/Utils.lean",
    deps = ["@lake//:Cli"],
    visibility = ["//visibility:public"],
)
```

---

## LEAN_PATH Construction

When compiling a module with external dependencies, `LEAN_PATH` must include:
1. The toolchain's stdlib `.olean` directory
2. Each dependency package's `.olean` output directory

The `lean_module` rule collects transitive `.olean` roots from dependencies and constructs `LEAN_PATH` accordingly.

---

## Key Design Decisions

### Why Use `lean --deps`?

We use Lean's built-in `--deps` flag (same as `lean_project`) because:
- It handles all import syntax correctly (including `public import`, conditional imports, etc.)
- It's maintained by the Lean team, so it stays in sync with language changes
- It only requires `LEAN_PATH` to be set, not pre-compiled `.olean` files

The `--deps` output lists expected `.olean` paths. We filter these to distinguish:
- **Local deps** (within the same package or other `@lake` packages)
- **Stdlib deps** (handled by the toolchain, no explicit Bazel dep needed)

### Why a Single @lake Repository?

All external packages are placed in a single `@lake` repository because:
1. **Simplicity**: One `use_repo(lean, "lake")` instead of listing each package
2. **Cross-package deps**: Packages like Cli that depend on Std resolve locally within `@lake`
3. **Consistent namespacing**: All external deps are under `@lake//:`
4. **Matches Lake model**: Lake manages all deps together in `.lake/packages/`

### Why Use Lake for Downloading but Not Building?

We use Lake for downloading because:
1. Lake handles git cloning, revision pinning, and transitive deps
2. Lake's manifest format is a well-defined lockfile
3. Users can use familiar Lake commands to manage deps

But we don't use Lake for compilation because:
1. Bazel loses visibility into the action graph
2. No incremental compilation at module granularity
3. Can't distribute compilation across remote workers
4. Duplicates work if multiple rules depend on same package

By generating `lean_module` targets, Bazel manages the full build while Lake manages the dependency resolution.

---

## Transitive Dependencies

If package A depends on B, and B depends on C:

```
lake-manifest.json (package A)
├── package B (direct dep)
│   └── package C (transitive dep, in B's .lake/packages/)
```

Lake flattens transitive deps into the top-level manifest. The module extension reads all packages from the manifest and includes them all in the `@lake` repository.

---

## Caching and Invalidation

The `@lake` repository invalidates when:
- Any git revision in `lake-manifest.json` changes
- The repository rule implementation changes

The `lean_module` compilation actions cache normally via Bazel.

---

## Example: Project with Cli Dependency

### Project Structure

```
myproject/
├── MODULE.bazel
├── BUILD.bazel
├── lakefile.toml
├── lake-manifest.json     # Generated by `lake update`
└── src/
    └── Main.lean          # imports Cli
```

### lakefile.toml

```toml
name = "myproject"
version = "0.1.0"

[[require]]
name = "Cli"
git = "https://github.com/leanprover/lean4-cli"
rev = "v4.27.0"

[[lean_lib]]
name = "MyProject"
```

### lake-manifest.json (generated)

```json
{
  "version": "1.1.0",
  "packagesDir": ".lake/packages",
  "packages": [
    {
      "name": "Cli",
      "url": "https://github.com/leanprover/lean4-cli",
      "rev": "55c37290ff6186e2e965d68cf853a57c0702db82",
      "inputRev": "v4.27.0",
      "type": "git"
    }
  ]
}
```

### Main.lean

```lean
import Cli

def main : IO Unit := do
  IO.println "Hello from Bazel + Lean!"
```

### BUILD.bazel

```python
load("@rules_lean//lean:defs.bzl", "lake_update", "lean_binary")

lake_update(name = "lake_update")

lean_binary(
    name = "myproject",
    deps = ["@myapp//:Main"],
)
```
