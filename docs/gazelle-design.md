# Gazelle for Lean: Design Document

## Overview

This document describes the design for `gazelle_lean`, a Gazelle extension that generates Bazel BUILD files for Lean 4 projects. The extension parses Lean source files to extract imports and generates `lean_module` targets with correct dependency relationships.

## Motivation

### Why Gazelle Instead of Multi-File Rules?

The Lean compiler does not support batch compilation of multiple `.lean` files to multiple `.c` files in a single invocation. Lake (Lean's build system) handles build ordering by:

1. Parsing imports from each source file using `Lean.parseImports'`
2. Building a dependency graph
3. Performing topological sort
4. Orchestrating compilation respecting the dependency order

In Bazel, action graphs must be declared at **analysis time** (before any actions run). This creates a fundamental tension:

| Approach | Problem |
|----------|---------|
| Single `lean_library(srcs = [...])` rule | Cannot determine inter-file dependencies at analysis time without running Lean |
| Run Lean at analysis time | Normal Bazel rules cannot execute code at analysis time |
| Reimplement import parser in Starlark | Fragile, must track Lean syntax changes |

**Gazelle solves this** by running before the build, using Lean's own tooling to extract imports, and generating BUILD files with explicit dependencies. This gives us:

- **Fine-grained caching**: Each file is a separate action
- **Explicit dependency graph**: Bazel sees the full graph at analysis time
- **Parallel builds**: Bazel parallelizes independent modules automatically
- **Lean semantics**: One module = one file = one target

## Architecture

### High-Level Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                     User runs: bazel run //:gazelle             │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  1. Discovery: Find all .lean files in the workspace            │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  2. Import Extraction: Run `lean --deps --json` on all files    │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  3. Module Mapping: Map import names to Bazel labels            │
│     - Local imports → relative labels (e.g., ":MyLib.Core")     │
│     - Stdlib imports → @lean_toolchain//:Init, etc.             │
│     - External imports → @external_repo//path:Module            │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  4. BUILD Generation: Generate lean_module targets with deps    │
└─────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  5. Merge: Merge with existing BUILD files, respecting # keep   │
└─────────────────────────────────────────────────────────────────┘
```

### Components

```
rules_lean/
├── gazelle/                          # Gazelle extension (Go)
│   ├── BUILD.bazel
│   ├── language.go                   # Language interface implementation
│   ├── config.go                     # Configurer: directives, flags
│   ├── generate.go                   # GenerateRules: parse files, emit rules
│   ├── resolve.go                    # Resolver: imports → labels
│   ├── kinds.go                      # KindInfo for lean_module, lean_binary
│   ├── parser/
│   │   ├── parser.go                 # Invoke `lean --deps --json`
│   │   └── types.go                  # JSON response types
│   └── testdata/                     # Test fixtures
├── lean/
│   ├── defs.bzl                      # Public API (adds lean_module)
│   └── private/
│       ├── rules.bzl                 # lean_binary (updated)
│       └── module.bzl                # lean_module rule (new)
└── def.bzl                           # gazelle_binary, gazelle macros
```

## New Bazel Rules

### `lean_module`

A `lean_module` represents a single Lean source file compiled to `.olean` (interface) and `.c` (C code).

```python
lean_module(
    name = "MyLib.Core",
    src = "MyLib/Core.lean",
    deps = [],  # Other lean_module targets
)
```

**Attributes**:

| Attribute | Type | Description |
|-----------|------|-------------|
| `name` | string | Target name, typically matches module name (e.g., `MyLib.Core`) |
| `src` | label | Single `.lean` source file |
| `deps` | label_list | Dependencies on other `lean_module` targets |
| `visibility` | label_list | Standard Bazel visibility |

**Providers**:

```python
LeanModuleInfo = provider(
    fields = {
        "module_name": "Fully qualified module name (e.g., 'MyLib.Core')",
        "olean": "The .olean file (compiled interface)",
        "ilean": "The .ilean file (incremental interface)",
        "c_source": "The generated .c file",
        "c_object": "The compiled .o file",
        "transitive_oleans": "depset of all transitive .olean files",
        "transitive_c_objects": "depset of all transitive .o files",
    },
)
```

**Actions**:

1. **LeanCompile**: `.lean` → `.olean` + `.ilean` + `.c`
   ```bash
   lean --root={root} --oleans={dep_oleans} {src} -c {output.c} -o {output.olean}
   ```

2. **CppCompile**: `.c` → `.o` (via `cc_common.compile`)

### `lean_binary` (Updated)

Updated to work with `lean_module` dependencies instead of compiling from source.

```python
lean_binary(
    name = "app",
    main = ":Main",  # A lean_module target with `main` function
    deps = [":Main"],  # Usually same as main, plus any additional deps
)
```

**Attributes**:

| Attribute | Type | Description |
|-----------|------|-------------|
| `name` | string | Target name |
| `main` | label | The `lean_module` containing the `main` function |
| `deps` | label_list | All `lean_module` dependencies (including transitive) |

**Actions**:

1. **CppLink**: Links all `.o` files from `deps` into an executable

### `lean_library` (New - Convenience Macro)

A macro that groups related `lean_module` targets for easier dependency management.

```python
lean_library(
    name = "mylib",
    modules = [
        ":MyLib",
        ":MyLib.Core",
        ":MyLib.Utils",
    ],
)
```

This creates a `filegroup` or alias that other packages can depend on, pulling in all the modules.

## Gazelle Extension Design

### Language Interface Implementation

```go
// language.go
package lean

import (
    "github.com/bazelbuild/bazel-gazelle/language"
)

type leanLang struct{}

func NewLanguage() language.Language {
    return &leanLang{}
}

func (*leanLang) Name() string { return "lean" }
```

### Configuration (Directives)

Gazelle directives control behavior per-directory via BUILD file comments:

```python
# BUILD.bazel

# gazelle:lean_root proj1
# Sets the module root for this directory tree.
# Files under proj1/MyLib/Core.lean get module name "MyLib.Core" instead of "proj1.MyLib.Core"

# gazelle:lean_exclude test/**
# Exclude files matching pattern from generation

# gazelle:lean_external mathlib @mathlib//
# Map external package "mathlib" to repository "@mathlib//"

# gazelle:lean_stdlib_repo @lean_toolchains
# Repository containing stdlib .olean files
```

**Directive Summary**:

| Directive | Description | Default |
|-----------|-------------|---------|
| `lean_root` | Module name prefix to strip | (workspace relative) |
| `lean_exclude` | Glob patterns to exclude | none |
| `lean_external` | Map package name to repository | none |
| `lean_stdlib_repo` | Stdlib repository name | `@lean_toolchains` |

### Import Extraction

The extension invokes `lean --deps --json` to extract imports:

```go
// parser/parser.go
package parser

import (
    "encoding/json"
    "os/exec"
)

type ImportInfo struct {
    Module    string `json:"module"`
    ImportAll bool   `json:"importAll"`
}

type FileImports struct {
    Imports  []ImportInfo `json:"imports"`
    IsModule bool         `json:"isModule"`
}

type DepsResult struct {
    Imports []struct {
        Result FileImports `json:"result"`
    } `json:"imports"`
}

func ParseImports(leanPath string, files []string) (*DepsResult, error) {
    args := append([]string{"--deps", "--json"}, files...)
    cmd := exec.Command(leanPath, args...)
    output, err := cmd.Output()
    if err != nil {
        return nil, err
    }

    var result DepsResult
    if err := json.Unmarshal(output, &result); err != nil {
        return nil, err
    }
    return &result, nil
}
```

### Module Name Resolution

Converting source paths to module names:

```go
// resolve.go

func moduleNameFromPath(path string, root string) string {
    // Remove root prefix if configured
    rel := strings.TrimPrefix(path, root+"/")

    // Remove .lean extension
    rel = strings.TrimSuffix(rel, ".lean")

    // Convert path separators to dots
    return strings.ReplaceAll(rel, "/", ".")
}

// Examples:
// moduleNameFromPath("MyLib/Core.lean", "") -> "MyLib.Core"
// moduleNameFromPath("proj1/MyLib/Core.lean", "proj1") -> "MyLib.Core"
```

### Import to Label Resolution

```go
// resolve.go

func (l *leanLang) Resolve(
    c *config.Config,
    ix *resolve.RuleIndex,
    rc *repo.RemoteCache,
    r *rule.Rule,
    imports interface{},
    from label.Label,
) {
    impList := imports.([]ImportInfo)
    var deps []string

    for _, imp := range impList {
        label := l.resolveImport(c, ix, imp.Module, from)
        if label != "" {
            deps = append(deps, label)
        }
    }

    if len(deps) > 0 {
        r.SetAttr("deps", deps)
    }
}

func (l *leanLang) resolveImport(
    c *config.Config,
    ix *resolve.RuleIndex,
    moduleName string,
    from label.Label,
) string {
    // 1. Check if it's a stdlib import (Init, Lean, Std, etc.)
    if isStdlibModule(moduleName) {
        // Stdlib modules are provided by the toolchain
        // They don't need explicit deps (available via LEAN_PATH)
        return ""
    }

    // 2. Check local index for a matching lean_module
    if matches := ix.FindRulesByImport(
        resolve.ImportSpec{Lang: "lean", Imp: moduleName},
        "lean",
    ); len(matches) > 0 {
        return matches[0].Label.String()
    }

    // 3. Check configured external mappings
    cfg := getLeanConfig(c)
    for pkg, repo := range cfg.ExternalMappings {
        if strings.HasPrefix(moduleName, pkg+".") {
            // Map to external repository
            rest := strings.TrimPrefix(moduleName, pkg+".")
            return repo + "//" + strings.ReplaceAll(rest, ".", "/") + ":" + rest
        }
    }

    // 4. Unable to resolve - will cause build error
    return ""
}

func isStdlibModule(name string) bool {
    prefixes := []string{"Init", "Lean", "Std", "Lake"}
    for _, p := range prefixes {
        if name == p || strings.HasPrefix(name, p+".") {
            return true
        }
    }
    return false
}
```

### Rule Generation

```go
// generate.go

func (l *leanLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
    var gen []*rule.Rule
    var imports []interface{}

    // Find all .lean files in this directory
    leanFiles := findLeanFiles(args.Dir, args.Config)

    if len(leanFiles) == 0 {
        return language.GenerateResult{}
    }

    // Parse imports for all files at once (batch mode)
    cfg := getLeanConfig(args.Config)
    depsResult, err := parser.ParseImports(cfg.LeanPath, leanFiles)
    if err != nil {
        // Log error, continue with empty deps
    }

    // Generate a lean_module for each .lean file
    for i, file := range leanFiles {
        moduleName := moduleNameFromPath(file, cfg.Root)

        r := rule.NewRule("lean_module", moduleName)
        r.SetAttr("src", file)

        gen = append(gen, r)

        // Store imports for resolution phase
        if depsResult != nil && i < len(depsResult.Imports) {
            imports = append(imports, depsResult.Imports[i].Result.Imports)
        } else {
            imports = append(imports, []ImportInfo{})
        }
    }

    return language.GenerateResult{
        Gen:     gen,
        Imports: imports,
    }
}
```

### Kind Definitions

```go
// kinds.go

func (*leanLang) Kinds() map[string]rule.KindInfo {
    return map[string]rule.KindInfo{
        "lean_module": {
            NonEmptyAttrs:  map[string]bool{"src": true},
            MergeableAttrs: map[string]bool{"deps": true},
        },
        "lean_binary": {
            NonEmptyAttrs:  map[string]bool{"main": true},
            MergeableAttrs: map[string]bool{"deps": true},
        },
        "lean_library": {
            NonEmptyAttrs:  map[string]bool{"modules": true},
            MergeableAttrs: map[string]bool{"modules": true},
        },
    }
}
```

## Generated BUILD File Examples

### Single Module

```
# Source: MyLib/Core.lean
# imports: Init.Data.String

MyLib/
├── BUILD.bazel
└── Core.lean
```

Generated BUILD.bazel:
```python
load("@rules_lean//lean:defs.bzl", "lean_module")

lean_module(
    name = "MyLib.Core",
    src = "Core.lean",
    # No deps - Init is stdlib
)
```

### Module with Local Dependencies

```
# MyLib.lean imports MyLib.Core and MyLib.Utils
# MyLib/Core.lean imports nothing local
# MyLib/Utils.lean imports MyLib.Core

MyLib/
├── BUILD.bazel
├── MyLib.lean
├── Core.lean
└── Utils.lean
```

Generated BUILD.bazel:
```python
load("@rules_lean//lean:defs.bzl", "lean_module")

lean_module(
    name = "MyLib",
    src = "MyLib.lean",
    deps = [
        ":MyLib.Core",
        ":MyLib.Utils",
    ],
)

lean_module(
    name = "MyLib.Core",
    src = "Core.lean",
)

lean_module(
    name = "MyLib.Utils",
    src = "Utils.lean",
    deps = [":MyLib.Core"],
)
```

### Binary with Dependencies

```
# Main.lean imports MyLib

app/
├── BUILD.bazel
├── Main.lean
└── MyLib/
    ├── Core.lean
    └── Utils.lean
```

Generated BUILD.bazel:
```python
load("@rules_lean//lean:defs.bzl", "lean_binary", "lean_module")

lean_binary(
    name = "app",
    main = ":Main",
    deps = [":Main"],
)

lean_module(
    name = "Main",
    src = "Main.lean",
    deps = [":MyLib"],
)

lean_module(
    name = "MyLib",
    src = "MyLib.lean",
    deps = [
        ":MyLib.Core",
        ":MyLib.Utils",
    ],
)

lean_module(
    name = "MyLib.Core",
    src = "MyLib/Core.lean",
)

lean_module(
    name = "MyLib.Utils",
    src = "MyLib/Utils.lean",
    deps = [":MyLib.Core"],
)
```

### Cross-Package Dependencies

```
# //app/Main.lean imports lib.Greeter (from //lib package)

lib/
├── BUILD.bazel
└── Greeter.lean

app/
├── BUILD.bazel
└── Main.lean
```

lib/BUILD.bazel:
```python
lean_module(
    name = "lib.Greeter",
    src = "Greeter.lean",
    visibility = ["//app:__pkg__"],
)
```

app/BUILD.bazel:
```python
lean_module(
    name = "Main",
    src = "Main.lean",
    deps = ["//lib:lib.Greeter"],
)

lean_binary(
    name = "app",
    main = ":Main",
    deps = [":Main"],
)
```

## User Experience

### Initial Setup

```python
# MODULE.bazel
bazel_dep(name = "rules_lean", version = "0.2.0")
bazel_dep(name = "bazel_gazelle", version = "0.35.0")

lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(version = "4.12.0")
use_repo(lean, "lean_toolchains")
register_toolchains("@lean_toolchains//:all")
```

```python
# BUILD.bazel (root)
load("@bazel_gazelle//:def.bzl", "gazelle", "gazelle_binary")
load("@rules_lean//gazelle:def.bzl", "lean_language")

gazelle_binary(
    name = "gazelle_bin",
    languages = [lean_language],
)

gazelle(
    name = "gazelle",
    gazelle = ":gazelle_bin",
)
```

### Running Gazelle

```bash
# Generate/update BUILD files for entire workspace
bazel run //:gazelle

# Generate for specific directory
bazel run //:gazelle -- path/to/dir

# Update dependencies only (faster)
bazel run //:gazelle -- update-repos
```

### Manual Overrides

Users can add `# keep` comments to prevent Gazelle from modifying specific lines:

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

## Implementation Phases

### Phase G1: Basic Module Generation

**Goal**: Generate `lean_module` targets for all `.lean` files.

**Scope**:
- Implement Gazelle extension scaffolding
- File discovery (find all `.lean` files)
- Generate `lean_module` with `src` attribute only
- No dependency resolution yet

**Success Criteria**:
- `bazel run //:gazelle` generates `lean_module` for each `.lean` file
- Generated BUILD files are syntactically valid

### Phase G2: Import Extraction

**Goal**: Extract imports using `lean --deps --json`.

**Scope**:
- Implement parser that invokes `lean --deps --json`
- Store imports for resolution phase
- Handle parse errors gracefully

**Success Criteria**:
- Imports are correctly extracted from Lean files
- Batch processing works for directories with many files

### Phase G3: Local Dependency Resolution

**Goal**: Resolve imports to local `lean_module` targets.

**Scope**:
- Module name → label mapping for same-package deps
- Cross-package dependency resolution
- Stdlib import filtering (no deps needed)

**Success Criteria**:
- `deps` attribute correctly populated
- `bazel build //...` succeeds for multi-file projects

### Phase G4: External Dependencies

**Goal**: Support external repositories by using Lake to fetch dependencies and generating Bazel BUILD files for them.

**Test Package**: [lean4-cli](https://github.com/leanprover/lean4-cli) - A small CLI argument parsing library with no transitive dependencies:
- 3 main modules: `Cli`, `Cli.Basic`, `Cli.Extensions`
- 2 test modules: `CliTest.Example`, `CliTest.Tests`
- Lean 4.27.0-rc1 toolchain

#### Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     User's Workspace                                         │
│                                                                              │
│  lakefile.toml (or lakefile.lean)    lake-manifest.json                      │
│  ─────────────────────────────────   ────────────────────                    │
│  [[require]]                         Pinned commits for                      │
│  name = "Cli"                        all transitive deps                     │
│  scope = "leanprover"                                                        │
└─────────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     lean_deps Repository Rule                                │
│                                                                              │
│  1. Reads lake-manifest.json to get all dependencies                         │
│  2. Runs `lake update` to download packages to .lake/packages/               │
│  3. For each package, generates BUILD.bazel with lean_module targets         │
│  4. Exports @lean_deps//<package>:<module> labels                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Generated External Repository                            │
│                                                                              │
│  @lean_deps//                                                                │
│  ├── Cli/                                                                    │
│  │   ├── BUILD.bazel     # lean_module targets for Cli modules               │
│  │   └── ...             # symlinked source files                            │
│  └── ...                 # other packages if any                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Lake Integration Strategy

Lake is Lean's native package manager and handles:
- Git cloning of dependencies
- Version resolution and pinning via manifest
- Pre-built release downloads (optional)

Rather than reimplementing this logic in Bazel, we leverage Lake to do what it does best:

1. **User maintains lakefile.toml** - Standard Lean workflow, no Bazel-specific config
2. **Lake downloads packages** - Repository rule invokes `lake update`
3. **Gazelle generates BUILD files** - Parse downloaded sources and generate targets

#### Repository Rule: `lean_deps`

```python
# lean/extensions.bzl

lean_deps = repository_rule(
    implementation = _lean_deps_impl,
    attrs = {
        "manifest": attr.label(
            doc = "Path to lake-manifest.json",
            allow_single_file = [".json"],
            mandatory = True,
        ),
        "lakefile": attr.label(
            doc = "Path to lakefile.toml or lakefile.lean",
            allow_single_file = True,
            mandatory = True,
        ),
        "_gazelle": attr.label(
            default = "@rules_lean//gazelle:gazelle_lean",
            executable = True,
            cfg = "exec",
        ),
    },
    environ = ["HOME"],  # Lake may need HOME for git
)

def _lean_deps_impl(ctx):
    # 1. Copy lakefile and manifest to repository directory
    ctx.symlink(ctx.attr.lakefile, "lakefile.toml")
    ctx.symlink(ctx.attr.manifest, "lake-manifest.json")

    # 2. Get lean toolchain path
    lean_toolchain = ctx.path(Label("@lean_toolchains//:lean"))
    lake_bin = lean_toolchain.dirname.get_child("lake")

    # 3. Run lake update to download all dependencies
    result = ctx.execute(
        [lake_bin, "update"],
        environment = {
            "HOME": ctx.os.environ.get("HOME", "/tmp"),
            "LAKE_HOME": str(ctx.path(".")),
        },
        timeout = 600,  # 10 min timeout for large deps like mathlib
    )
    if result.return_code != 0:
        fail("lake update failed: " + result.stderr)

    # 4. Parse manifest to get list of packages
    manifest = json.decode(ctx.read("lake-manifest.json"))

    # 5. For each package, generate BUILD.bazel
    for pkg in manifest["packages"]:
        pkg_name = pkg["name"]
        pkg_dir = ".lake/packages/" + pkg_name

        # Run gazelle on the package directory
        result = ctx.execute(
            [ctx.attr._gazelle, "-mode", "fix", pkg_dir],
            timeout = 120,
        )

        # Create top-level alias for the package
        _write_package_build(ctx, pkg_name, pkg_dir)

    # 6. Write root BUILD.bazel that exports all packages
    _write_root_build(ctx, manifest["packages"])
```

#### Manifest Schema (lake-manifest.json)

Lake manifest files contain pinned versions of all transitive dependencies:

```json
{
  "version": "1.1.0",
  "packagesDir": ".lake/packages",
  "name": "my-project",
  "packages": [
    {
      "type": "git",
      "name": "mathlib",
      "scope": "leanprover-community",
      "url": "https://github.com/leanprover-community/mathlib4",
      "rev": "abc123...",  // Exact commit SHA
      "inputRev": "v4.15.0",  // Requested version
      "inherited": false,
      "configFile": "lakefile.toml"
    },
    {
      "type": "git",
      "name": "batteries",
      "url": "https://github.com/leanprover-community/batteries",
      "rev": "def456...",
      "inherited": true,  // Transitive dep of mathlib
      ...
    }
  ]
}
```

#### Generated BUILD Structure

For each external package, generate BUILD.bazel with lean_module targets:

```python
# @lean_deps//Cli/BUILD.bazel (generated)
load("@rules_lean//lean:defs.bzl", "lean_module")

# One lean_module per .lean file in the package
lean_module(
    name = "Cli",
    src = "Cli.lean",
    deps = [":Cli.Basic", ":Cli.Extensions"],
    visibility = ["//visibility:public"],
)

lean_module(
    name = "Cli.Basic",
    src = "Cli/Basic.lean",
    visibility = ["//visibility:public"],
)

lean_module(
    name = "Cli.Extensions",
    src = "Cli/Extensions.lean",
    deps = [":Cli.Basic"],
    visibility = ["//visibility:public"],
)
```

#### Module Extension API

Users configure external deps via module extension:

```python
# MODULE.bazel
lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")

# Register external dependencies from Lake manifest
lean.deps(
    name = "lean_deps",
    manifest = "//:lake-manifest.json",
    lakefile = "//:lakefile.toml",
)

use_repo(lean, "lean_deps")
```

#### Gazelle Import Resolution Updates

Update resolve.go to handle imports from external packages:

```go
func (l *leanLang) resolveImport(
    c *config.Config,
    ix *resolve.RuleIndex,
    moduleName string,
    from label.Label,
) string {
    // 1. Check stdlib (unchanged)
    if isStdlibImport(moduleName) {
        return ""
    }

    // 2. Check local index (unchanged)
    if matches := ix.FindRulesByImport(...); len(matches) > 0 {
        return matches[0].Label.String()
    }

    // 3. Check external packages from Lake manifest
    cfg := getLeanConfig(c)
    for _, pkg := range cfg.LakePackages {
        // Check if import starts with package's module prefix
        // e.g., "Cli" or "Cli.Basic" matches package with ModuleRoot "Cli"
        if strings.HasPrefix(moduleName, pkg.ModuleRoot+".") || moduleName == pkg.ModuleRoot {
            // Map to @lean_deps//<package>:<module>
            // e.g., import Cli.Basic -> @lean_deps//Cli:Cli.Basic
            return "@lean_deps//" + pkg.Name + ":" + moduleName
        }
    }

    return ""
}
```

#### Pre-built Release Support

For large packages like Mathlib, building from source is slow. Lake supports pre-built releases:

```python
def _lean_deps_impl(ctx):
    # ... after lake update ...

    # Check for pre-built .olean files
    for pkg in manifest["packages"]:
        release_dir = ".lake/packages/" + pkg["name"] + "/.lake/build"
        if ctx.path(release_dir).exists:
            # Package has pre-built artifacts - use them
            _import_prebuilt_oleans(ctx, pkg)
        else:
            # Need to build from source - generate lean_module targets
            _generate_build_file(ctx, pkg)
```

#### Scope

- `lean_deps` repository rule that reads lake-manifest.json
- Lake integration for downloading packages
- BUILD.bazel generation for external packages
- Gazelle resolver updates for `@lean_deps//` imports
- Module extension API for users

#### Implementation Sub-phases

**G4.1: Repository Rule Skeleton**
- Implement `lean_deps` repository rule
- Read and parse lake-manifest.json
- Invoke `lake update` to download packages

**G4.2: BUILD Generation for External Packages**
- Scan downloaded package sources for .lean files
- Parse imports using existing parser
- Generate lean_module targets with deps

**G4.3: Gazelle Resolver Integration**
- Load Lake manifest into Gazelle config
- Map external imports to `@lean_deps//pkg:Module` labels
- Handle transitive dependencies between external packages

**G4.4: Pre-built Release Support (Optional)**
- Detect when packages have pre-built .olean/.o files
- Import artifacts directly instead of compiling from source
- Significant build time improvement for Mathlib

**Success Criteria**:
- Projects with `lakefile.toml` + `lake-manifest.json` can build with Bazel
- Imports like `import Cli` and `import Cli.Basic` resolve to `@lean_deps//Cli:Cli` and `@lean_deps//Cli:Cli.Basic`
- External package modules are cached and reusable across builds
- Test with lean4-cli: user project can `import Cli` and use CLI parsing functionality

### Phase G4.5: Manifest Generation (`lake_manifest` rule)

**Goal**: Provide a `pip_compile`-style rule for generating/updating `lake-manifest.json`.

#### Motivation

Currently, users must run `lake update` outside of Bazel to generate the manifest file. This creates friction:
- Requires Lake to be installed separately
- Easy to forget to update the manifest
- No Bazel integration for the workflow

Similar to how `pip_compile` in rules_python provides `bazel run //:requirements.update`, we provide `lake_manifest` with an `.update` target.

#### User Workflow

```python
# BUILD.bazel
load("@rules_lean//lean:defs.bzl", "lake_manifest")

lake_manifest(
    name = "lake_manifest",
    lakefile = "lakefile.toml",
    manifest = "lake-manifest.json",
)
```

```bash
# Update the manifest when dependencies change
bazel run //:lake_manifest.update

# Validate manifest is up-to-date (useful in CI)
bazel test //:lake_manifest_test
```

#### Implementation

The rule generates two targets:

1. **`lake_manifest`** - A filegroup containing the manifest (for use as dependency)
2. **`lake_manifest.update`** - An executable that runs `lake update` and writes the manifest

```python
# lean/private/lake_manifest.bzl

def _lake_manifest_update_impl(ctx):
    """Implementation for the .update target that regenerates the manifest."""

    # Create a shell script that:
    # 1. Changes to the source directory (where lakefile.toml lives)
    # 2. Runs `lake update`
    # 3. Copies the generated manifest back to the source tree

    script = ctx.actions.declare_file(ctx.label.name + ".sh")

    # Get the Lake binary from the toolchain
    lean_toolchain = ctx.toolchains["@rules_lean//lean:toolchain_type"]
    lake = lean_toolchain.lake

    ctx.actions.write(
        output = script,
        content = """\
#!/bin/bash
set -euo pipefail

LAKEFILE_DIR=$(dirname "{lakefile}")
cd "$BUILD_WORKSPACE_DIRECTORY/$LAKEFILE_DIR"

# Run lake update
"{lake}" update

echo "Updated {manifest}"
""".format(
            lakefile = ctx.file.lakefile.short_path,
            lake = lake.short_path,
            manifest = ctx.file.manifest.short_path,
        ),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [lake, ctx.file.lakefile]),
    )]

lake_manifest_update = rule(
    implementation = _lake_manifest_update_impl,
    attrs = {
        "lakefile": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "manifest": attr.label(
            allow_single_file = [".json"],
            mandatory = True,
        ),
    },
    executable = True,
    toolchains = ["@rules_lean//lean:toolchain_type"],
)

def _lake_manifest_test_impl(ctx):
    """Test that validates the manifest is up-to-date."""

    script = ctx.actions.declare_file(ctx.label.name + ".sh")

    lean_toolchain = ctx.toolchains["@rules_lean//lean:toolchain_type"]
    lake = lean_toolchain.lake

    ctx.actions.write(
        output = script,
        content = """\
#!/bin/bash
set -euo pipefail

# Create temp directory for validation
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Copy lakefile to temp
cp "{lakefile}" "$TMPDIR/lakefile.toml"

cd "$TMPDIR"

# Run lake update
"{lake}" update 2>/dev/null

# Compare generated manifest with checked-in version
if ! diff -q lake-manifest.json "{manifest}" > /dev/null 2>&1; then
    echo "ERROR: lake-manifest.json is out of date!"
    echo "Run: bazel run //{pkg}:{name}.update"
    exit 1
fi

echo "lake-manifest.json is up to date"
""".format(
            lakefile = ctx.file.lakefile.short_path,
            manifest = ctx.file.manifest.short_path,
            lake = lake.short_path,
            pkg = ctx.label.package,
            name = ctx.label.name.removesuffix("_test"),
        ),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = script,
        runfiles = ctx.runfiles(files = [lake, ctx.file.lakefile, ctx.file.manifest]),
    )]

lake_manifest_test = rule(
    implementation = _lake_manifest_test_impl,
    attrs = {
        "lakefile": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "manifest": attr.label(
            allow_single_file = [".json"],
            mandatory = True,
        ),
    },
    test = True,
    toolchains = ["@rules_lean//lean:toolchain_type"],
)

def lake_manifest(name, lakefile, manifest, **kwargs):
    """Macro that creates targets for managing Lake manifest files.

    Similar to pip_compile in rules_python, this creates:
    - {name}: A filegroup containing the manifest
    - {name}.update: Executable to regenerate the manifest
    - {name}_test: Test to validate manifest is up-to-date

    Args:
        name: Base name for the targets
        lakefile: Label for lakefile.toml
        manifest: Label for lake-manifest.json
        **kwargs: Additional arguments passed to all targets

    Example:
        lake_manifest(
            name = "lake_manifest",
            lakefile = "lakefile.toml",
            manifest = "lake-manifest.json",
        )

        # Update manifest: bazel run //:lake_manifest.update
        # Validate in CI: bazel test //:lake_manifest_test
    """

    # Main target - filegroup with the manifest
    native.filegroup(
        name = name,
        srcs = [manifest],
        **kwargs
    )

    # Update target
    lake_manifest_update(
        name = name + ".update",
        lakefile = lakefile,
        manifest = manifest,
        **kwargs
    )

    # Test target for CI
    lake_manifest_test(
        name = name + "_test",
        lakefile = lakefile,
        manifest = manifest,
        **kwargs
    )
```

#### Comparison with pip_compile

| Feature | pip_compile | lake_manifest |
|---------|-------------|---------------|
| Input file | requirements.in / pyproject.toml | lakefile.toml |
| Output file | requirements.txt | lake-manifest.json |
| Update command | `bazel run //:requirements.update` | `bazel run //:lake_manifest.update` |
| Validation test | `bazel test //:requirements_test` | `bazel test //:lake_manifest_test` |
| Resolver | pip-tools | lake update |
| Lock format | Package==version with hashes | Git commit SHAs |

#### Success Criteria

- `bazel run //:lake_manifest.update` regenerates lake-manifest.json
- `bazel test //:lake_manifest_test` passes when manifest is up-to-date
- `bazel test //:lake_manifest_test` fails when lakefile.toml has new deps not in manifest
- Integrates with existing `lean.deps()` module extension

### Phase G5: Binary Detection

**Goal**: Automatically detect and generate `lean_binary` targets.

**Scope**:
- Detect files containing `def main : IO Unit`
- Generate `lean_binary` with appropriate `main` and `deps`
- Handle multiple binaries in one package

**Success Criteria**:
- `bazel run` works for auto-detected binaries

## Open Questions

1. **How to handle `import all` syntax?** - Needs special handling to import all modules from a package.

2. ~~**Lake manifest integration**~~ - **Resolved in Phase G4**: Use Lake to download packages, generate BUILD files from downloaded sources.

3. **Incremental updates** - How to efficiently update only changed files without re-parsing everything?

4. **Module root configuration** - Best UX for configuring module name prefixes in monorepos?

5. **Generated code** - How to handle imports from Lean files that are themselves generated by other rules?

6. **External package build performance** - Mathlib has ~1M+ lines of code across thousands of modules. Options:
   - Support pre-built release downloads (Lake's `preferReleaseBuild`)
   - Implement parallel gazelle processing for large packages
   - Consider caching generated BUILD files

7. **Lean version compatibility** - External packages may require specific Lean versions. How to handle version mismatches between workspace toolchain and package requirements?

## Appendix: Lean Import Syntax

```lean
-- Standard import
import Init.Data.String

-- Import with re-export (default)
import Mathlib.Algebra

-- Private import (not re-exported)
private import Internal.Utils

-- Import all from package
import all MyPackage

-- Meta import (for transitive IR)
meta import SomePackage
```

The `--deps --json` output includes flags for `importAll`, `isExported`, and `isMeta`.
