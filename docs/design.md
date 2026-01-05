# rules_lean Design Document

## Overview

`rules_lean` provides Bazel rules for building Lean 4 projects. The goal is to bring Bazel's benefits (hermeticity, caching, remote execution, polyglot builds) to the Lean ecosystem.

## Goals

- **Hermetic builds**: Toolchain is downloaded and managed by Bazel
- **Incremental**: Fine-grained caching at the file level
- **Remote execution ready**: Actions are sandboxable and can run on RBE
- **Ecosystem integration**: Parse `lake-manifest.json` to import existing dependencies
- **Polyglot support**: Lean code can integrate with C/C++ and other Bazel-built languages

## Non-Goals

- Replace Lake for Lean-only projects that don't need Bazel's features
- Support Lean 3 (Lean 4 only)

## Testing Strategy

- **Starlark unit tests**: Use `bazel_skylib`'s unittest framework for rule logic, providers, and action construction
- **Integration tests**: Each phase has a corresponding example in `examples/` that serves as an end-to-end test

### CI Structure

All CI workflows follow a consistent pattern for local reproducibility:

```
.github/workflows/
├── test-toolchain.yml              # GitHub Actions workflow (orchestration only)
└── test-toolchain/
    ├── Dockerfile                  # Orchestration only - calls scripts
    ├── step-1.1-install-deps.sh    # Install system dependencies
    ├── step-2.1-test-registration.sh
    └── step-2.2-test-expected-targets.sh
```

Note: Bazel is provided hermetically via `./bazel` at the repo root, so no Bazel installation step is needed.

**Principles**:
1. **Workflow files** (`.yml`) only orchestrate - they call scripts, never contain inline bash
2. **Dockerfiles** only orchestrate - they call scripts, never contain inline commands (except `COPY`/`WORKDIR`)
3. **Scripts** (`.sh`) contain all logic and live in a subdirectory matching the workflow name
4. **Script naming**: `step-X.Y-description.sh` where X is stage number, Y is step within stage

**Example workflow file**:
```yaml
# .github/workflows/test-toolchain.yml
name: Test Toolchain Registration
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install dependencies
        run: .github/workflows/test-toolchain/step-1.1-install-deps.sh
      - name: Test registration
        run: .github/workflows/test-toolchain/step-2.1-test-registration.sh
      - name: Test expected targets
        run: .github/workflows/test-toolchain/step-2.2-test-expected-targets.sh
```

**Example Dockerfile**:
```dockerfile
# .github/workflows/test-toolchain/Dockerfile
FROM ubuntu:latest
COPY . /workspace
WORKDIR /workspace
RUN .github/workflows/test-toolchain/step-1.1-install-deps.sh
RUN .github/workflows/test-toolchain/step-2.1-test-registration.sh
RUN .github/workflows/test-toolchain/step-2.2-test-expected-targets.sh
```

**Local replication**:
```bash
docker build -f .github/workflows/test-toolchain/Dockerfile .
```

---

## Phases

Each phase has:
- **Success criteria**: What must work for the phase to be complete
- **Example**: Working code in `examples/XX_name/`
- **Unit tests**: Starlark tests covering the new functionality

---

### Phase 1: Toolchain Acquisition

**Goal**: Download and register the Lean toolchain.

**Success Criteria**:
- `lean.toolchain(version = "4.12.0")` in MODULE.bazel downloads Lean for the host platform
- `lean_toolchain` target is resolvable
- `LeanToolchainInfo` provider exposes paths to `lean`, `leanc`, standard library `.olean` files

**User Experience**:
```python
# MODULE.bazel
bazel_dep(name = "rules_lean", version = "0.1.0")

lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(version = "4.12.0")
use_repo(lean, "lean_toolchains")

register_toolchains("@lean_toolchains")
```

**Example**: `examples/01_toolchain/`

**Tests**:

Following rules_rust's pattern, we test toolchain logic without actual downloads. Each test type validates specific requirements:

#### 1. Unit tests (`unittest` from bazel_skylib)

Test pure helper functions in isolation - no Bazel rules, no network.

| Test | Requirement validated | What breaks if this fails |
|------|----------------------|---------------------------|
| `_produce_tool_url_test` | URL construction matches Lean's GitHub release format | Downloads fail with 404 |
| `_sha256_lookup_test` | Known SHA256 hashes are retrievable by version | Downloads fail integrity check |
| `_parse_version_test` | Version strings like "4.12.0" parse correctly | Wrong toolchain selected |
| `_platform_triple_test` | OS/arch maps to correct triple (e.g., "linux-x86_64") | Wrong binary downloaded for platform |

```python
# test/unit/toolchain/toolchain_utils_test.bzl
def _produce_tool_url_test_impl(ctx):
    env = unittest.begin(ctx)

    # Requirement: URL format matches https://github.com/leanprover/lean4/releases
    asserts.equals(
        env,
        "https://github.com/leanprover/lean4/releases/download/v4.12.0/lean-4.12.0-linux.tar.zst",
        produce_tool_url("4.12.0", "linux"),
    )

    return unittest.end(env)
```

#### 2. Analysis tests (`analysistest` from bazel_skylib)

Test that Bazel rules produce correct providers, using mock toolchains (no downloads).

| Test | Requirement validated | What breaks if this fails |
|------|----------------------|---------------------------|
| `_toolchain_provider_fields_test` | `LeanToolchainInfo` has all required fields | Rules that consume toolchain crash at analysis time |
| `_toolchain_executables_test` | `lean` and `leanc` are marked as executable files | Compilation actions fail with "permission denied" |
| `_stdlib_oleans_test` | Standard library `.olean` files are exposed | `import Init` and other stdlib imports fail |

```python
# test/unit/toolchain/toolchain_test.bzl
def _toolchain_provider_fields_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    toolchain_info = target[platform_common.ToolchainInfo]

    # Requirement: Provider must expose lean executable
    # If missing: lean_binary rule will fail with "toolchain has no 'lean' attribute"
    asserts.true(env, hasattr(toolchain_info, "lean"), "lean executable must be exposed")

    # Requirement: Provider must expose leanc (C backend compiler)
    # If missing: linking native binaries will fail
    asserts.true(env, hasattr(toolchain_info, "leanc"), "leanc executable must be exposed")

    # Requirement: Version must be stored for compatibility checks
    # If missing: can't verify stdlib cache matches toolchain version
    asserts.equals(env, "4.12.0", toolchain_info.version)

    return analysistest.end(env)
```

#### 3. Integration test (GitHub Actions)

Test actual download and registration - the only test that hits the network.

| Test | Requirement validated | What breaks if this fails |
|------|----------------------|---------------------------|
| `bazel query @lean_toolchain_linux_x86_64//...` | Toolchain registration doesn't error | Users can't use rules_lean at all |
| Validate expected targets exist | Downloaded files match expected structure | Compilation will fail with missing files |

```bash
#!/bin/bash
# .github/workflows/test-toolchain/step-2.1-test-registration.sh
set -euo pipefail

cd examples/01_toolchain

# Verify toolchain registers without error
../../bazel query @lean_toolchain_linux_x86_64//...
```

---

### Phase 2: Hello World Binary

**Goal**: Compile and run a single-file Lean binary.

**Success Criteria**:
- `lean_binary(name = "hello", src = "Main.lean")` produces a runnable executable
- `bazel run //examples/02_hello_world` prints output
- Exit code is propagated correctly

**User Experience**:
```python
# BUILD.bazel
load("@rules_lean//lean:defs.bzl", "lean_binary")

lean_binary(
    name = "hello",
    src = "Main.lean",
)
```

```lean
-- Main.lean
def main : IO Unit :=
  IO.println "Hello, World!"
```

**Example**: `examples/02_hello_world/`

**Unit Tests**:
- Binary action has correct inputs/outputs
- Lean compiler flags are passed correctly

---

### Phase 3: Single Library

**Goal**: Compile a single-file Lean library.

**Success Criteria**:
- `lean_library(name = "mylib", src = "MyLib.lean")` produces `.olean` file
- `LeanLibraryInfo` provider exposes olean paths
- Library can be used as a dependency (tested in Phase 4)

**User Experience**:
```python
# BUILD.bazel
load("@rules_lean//lean:defs.bzl", "lean_library")

lean_library(
    name = "greeter",
    src = "Greeter.lean",
)
```

```lean
-- Greeter.lean
def greet (name : String) : String :=
  s!"Hello, {name}!"
```

**Example**: `examples/03_single_library/`

**Unit Tests**:
- Library provider contains olean path
- Output path follows Lean conventions

---

### Phase 4: Library Dependency

**Goal**: A binary can depend on a library and import it.

**Success Criteria**:
- `lean_binary` with `deps = [":mylib"]` compiles successfully
- `import MyLib` resolves correctly
- Transitive dependencies work

**User Experience**:
```python
# BUILD.bazel
load("@rules_lean//lean:defs.bzl", "lean_binary", "lean_library")

lean_library(
    name = "greeter",
    src = "Greeter.lean",
)

lean_binary(
    name = "hello",
    src = "Main.lean",
    deps = [":greeter"],
)
```

```lean
-- Main.lean
import Greeter

def main : IO Unit :=
  IO.println (greet "Bazel")
```

**Example**: `examples/04_library_deps/`

**Unit Tests**:
- Import paths are constructed correctly
- Dependency oleans are passed to compiler

---

### Phase 5: Multi-file Library

**Goal**: A library with multiple source files and internal imports.

**Success Criteria**:
- `lean_library(srcs = ["A.lean", "B.lean"])` handles internal imports
- Build order respects dependencies between files
- Parallel compilation where possible

**User Experience**:
```python
# BUILD.bazel
load("@rules_lean//lean:defs.bzl", "lean_library")

lean_library(
    name = "mylib",
    srcs = [
        "MyLib/Core.lean",
        "MyLib/Utils.lean",
        "MyLib.lean",
    ],
)
```

**Example**: `examples/05_multi_file/`

**Unit Tests**:
- Dependency analysis extracts imports
- Action graph respects file dependencies

---

### Phase 6: Remote Execution

**Goal**: Builds work correctly with remote caching and execution.

**Success Criteria**:
- Actions are hermetic (no undeclared inputs)
- Remote cache hits work correctly
- RBE execution succeeds

**User Experience**:
```bash
bazel build //... --remote_cache=grpcs://cache.example.com
bazel build //... --remote_executor=grpcs://rbe.example.com
```

**Example**: CI configuration demonstrating remote cache usage

**Unit Tests**:
- Actions declare all inputs
- No absolute paths in action commands

---

### Phase 7: Lake Manifest Parsing

**Goal**: Generate Bazel repositories from `lake-manifest.json`.

**Success Criteria**:
- Repository rule reads `lake-manifest.json`
- Generates `BUILD.bazel` files for each dependency
- Dependencies are usable from local `lean_library`/`lean_binary` targets

**User Experience**:
```python
# MODULE.bazel
lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.from_lake_manifest(
    name = "lake_deps",
    manifest = "//:lake-manifest.json",
)
use_repo(lean, "lake_deps")
```

```python
# BUILD.bazel
lean_binary(
    name = "app",
    src = "Main.lean",
    deps = ["@lake_deps//std4"],
)
```

**Example**: `examples/07_lake_import/`

**Unit Tests**:
- Manifest parsing extracts package info
- Generated BUILD files are valid

---

### Phase 8: Prebuilt Cache Support

**Goal**: Use prebuilt `.olean` files instead of building from source.

**Success Criteria**:
- Can download and use `.olean` caches for dependencies
- Version matching between toolchain and cache
- Fallback to source build if cache unavailable

**User Experience**:
```python
# MODULE.bazel
lean.from_lake_manifest(
    name = "lake_deps",
    manifest = "//:lake-manifest.json",
    use_cache = True,  # Download prebuilt oleans when available
)
```

**Example**: `examples/08_prebuilt_cache/`

**Unit Tests**:
- Cache URL construction is correct
- Version mismatch triggers source build

---

### Phase 9: Bazel CC Toolchain Integration

**Goal**: Use Bazel's `cc_toolchain` instead of bundled `leanc` for native code compilation.

**Motivation**:
The Lean distribution bundles `leanc`, which wraps a specific Clang version (e.g., 15.0.1). While this provides hermetic builds out of the box, advanced users may want to:
- Use a specific compiler version for their platform
- Share a single C toolchain across Lean and C/C++ code in polyglot builds
- Use platform-specific compiler optimizations
- Comply with organizational toolchain requirements

**Success Criteria**:
- `lean_binary` and `lean_library` can optionally use Bazel's resolved `cc_toolchain`
- C code generated by Lean compiles with user's CC toolchain
- Linking uses CC toolchain's linker
- Bundled `leanc` remains the default for simplicity

**User Experience**:
```python
# MODULE.bazel
bazel_dep(name = "rules_cc", version = "0.0.9")

lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(
    version = "4.12.0",
    use_cc_toolchain = True,  # Use Bazel's CC toolchain instead of bundled leanc
)
```

```python
# BUILD.bazel
lean_binary(
    name = "hello",
    src = "Main.lean",
    # Inherits cc_toolchain from toolchain config, or can override:
    # cc_toolchain = "//my:custom_cc_toolchain",
)
```

**Example**: `examples/09_cc_toolchain/`

**Unit Tests**:
- When `use_cc_toolchain = True`, compile actions use CC toolchain's compiler
- Linking actions use CC toolchain's linker
- Include paths from CC toolchain are passed to Lean's C code generation

---

## Open Questions

- **Module naming**: How to map Bazel target names to Lean module names?
- **Lean version pinning**: How strict should toolchain version matching be?
- **FFI support**: When/how to add C interop support?
