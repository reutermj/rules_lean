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

## Module Naming

Lean module names are derived from the source file path relative to a "root" directory. In `rules_lean`, module names are derived from the **source file path relative to the Bazel workspace root**.

### Why Workspace-Relative?

In a monorepo with multiple Lean projects, workspace-relative paths provide natural namespacing:

```
//proj1/utils/Foo.lean  → module proj1.utils.Foo
//proj2/utils/Foo.lean  → module proj2.utils.Foo
```

Without this, both files would have module name `utils.Foo`, causing conflicts.

### Examples

| Source file path | Module name |
|------------------|-------------|
| `Main.lean` | `Main` |
| `lib/Utils.lean` | `lib.Utils` |
| `proj1/Bar/Foo.lean` | `proj1.Bar.Foo` |
| `src/MyApp/Core.lean` | `src.MyApp.Core` |

### Cross-Project Dependencies

To import a module from another Bazel package:

```python
# //proj2/BUILD.bazel
lean_binary(
    name = "app",
    src = "Main.lean",
    deps = ["//proj1/utils:foo"],
)
```

```lean
-- proj2/Main.lean
import proj1.utils.Foo  -- module name derived from source path

def main : IO Unit :=
  IO.println Foo.greet
```

### Comparison with Lake

Lake derives module names from paths relative to the package root (where `lakefile.lean` lives). In `rules_lean`, the "package root" is effectively the workspace root, which provides consistent namespacing across the entire monorepo.

## Testing Strategy

- **Starlark unit tests**: Use `rules_testing` for rule logic, providers, and action construction (fluent Truth-style assertions)
- **Integration tests**: Each phase has a corresponding example in `examples/` that serves as an end-to-end test

### Testing Dependencies

```python
# MODULE.bazel
bazel_dep(name = "rules_testing", version = "0.7.0", dev_dependency = True)
```

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

#### 1. Unit tests (`rules_testing`)

Test pure helper functions in isolation using fluent Truth-style assertions.

| Test | Requirement validated | What breaks if this fails |
|------|----------------------|---------------------------|
| `test_produce_tool_url` | URL construction matches Lean's GitHub release format | Downloads fail with 404 |
| `test_sha256_lookup` | Known SHA256 hashes are retrievable by version | Downloads fail integrity check |
| `test_parse_version` | Version strings like "4.12.0" parse correctly | Wrong toolchain selected |
| `test_platform_triple` | OS/arch maps to correct triple (e.g., "linux-x86_64") | Wrong binary downloaded for platform |

```python
# test/unit/toolchain/toolchain_utils_test.bzl
load("@rules_testing//lib:analysis_test.bzl", "test_suite")
load("@rules_testing//lib:truth.bzl", "subjects")
load("//lean/private:toolchain_utils.bzl", "produce_tool_url")

def _test_produce_tool_url(env):
    # Requirement: URL format matches https://github.com/leanprover/lean4/releases
    result = produce_tool_url("4.12.0", "linux")
    env.expect.that_str(result).equals(
        "https://github.com/leanprover/lean4/releases/download/v4.12.0/lean-4.12.0-linux.tar.zst"
    )

def toolchain_utils_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_produce_tool_url,
            # ... other tests
        ],
    )
```

#### 2. Analysis tests (`rules_testing`)

Test that Bazel rules produce correct providers, using mock toolchains (no downloads).

| Test | Requirement validated | What breaks if this fails |
|------|----------------------|---------------------------|
| `test_toolchain_provider_fields` | `LeanToolchainInfo` has all required fields | Rules that consume toolchain crash at analysis time |
| `test_toolchain_executables` | `lean` and `leanc` are marked as executable files | Compilation actions fail with "permission denied" |
| `test_stdlib_oleans` | Standard library `.olean` files are exposed | `import Init` and other stdlib imports fail |

```python
# test/unit/toolchain/toolchain_test.bzl
load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("@rules_testing//lib:util.bzl", "util")
load("//lean:defs.bzl", "lean_toolchain")

def _test_toolchain_provider_fields(name):
    util.helper_target(
        lean_toolchain,
        name = name + "_subject",
        version = "4.12.0",
        lean = "//test:mock_lean",
        leanc = "//test:mock_leanc",
    )

    analysis_test(
        name = name,
        target = name + "_subject",
        impl = _test_toolchain_provider_fields_impl,
    )

def _test_toolchain_provider_fields_impl(env, target):
    # Fluent assertions for provider fields
    env.expect.that_target(target).has_provider(platform_common.ToolchainInfo)

    toolchain_info = target[platform_common.ToolchainInfo]
    env.expect.that_str(toolchain_info.version).equals("4.12.0")
    env.expect.that_bool(hasattr(toolchain_info, "lean")).is_true()
    env.expect.that_bool(hasattr(toolchain_info, "leanc")).is_true()
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

**Tests**:

Following the same pattern as Phase 1, we test rule logic at analysis time and end-to-end behavior with integration tests.

#### 1. Unit tests (`rules_testing`)

Test pure helper functions used by `lean_binary`.

| Test | Requirement validated | What breaks if this fails |
|------|----------------------|---------------------------|
| `test_module_name_from_path` | `Main.lean` → module name `Main` | Wrong module passed to compiler |
| `test_output_path_construction` | Binary output path follows conventions | Can't find compiled binary |
| `test_compiler_flags_default` | Default flags are sensible | Compilation fails or produces bad output |

```python
# test/unit/rules/lean_binary_utils_test.bzl
load("@rules_testing//lib:analysis_test.bzl", "test_suite")
load("//lean/private:utils.bzl", "module_name_from_path")

def _test_module_name_from_path(env):
    env.expect.that_str(module_name_from_path("Main.lean")).equals("Main")
    env.expect.that_str(module_name_from_path("src/App.lean")).equals("App")
    env.expect.that_str(module_name_from_path("MyModule/Sub.lean")).equals("Sub")

def lean_binary_utils_test_suite(name):
    test_suite(name = name, tests = [_test_module_name_from_path])
```

#### 2. Analysis tests (`rules_testing`)

Test that `lean_binary` produces correct providers and actions without actually compiling.

| Test | Requirement validated | What breaks if this fails |
|------|----------------------|---------------------------|
| `test_lean_binary_produces_executable` | `DefaultInfo` contains an executable | `bazel run` fails |
| `test_lean_binary_actions` | Correct compilation and linking actions registered | Build fails or produces wrong output |
| `test_lean_binary_toolchain_inputs` | Actions depend on toolchain files | Hermetic builds broken |
| `test_lean_binary_source_inputs` | Source file is an action input | Changes don't trigger rebuild |

```python
# test/unit/rules/lean_binary_test.bzl
load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("@rules_testing//lib:util.bzl", "util")
load("//lean:defs.bzl", "lean_binary")

def _test_lean_binary_produces_executable(name):
    util.helper_target(
        lean_binary,
        name = name + "_subject",
        src = "Main.lean",
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        target = name + "_subject",
        impl = _test_lean_binary_produces_executable_impl,
    )

def _test_lean_binary_produces_executable_impl(env, target):
    # Verify DefaultInfo has an executable
    default_info = target[DefaultInfo]
    env.expect.that_bool(
        default_info.files_to_run.executable != None
    ).is_true()

def _test_lean_binary_actions(name):
    util.helper_target(
        lean_binary,
        name = name + "_subject",
        src = "Main.lean",
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        target = name + "_subject",
        impl = _test_lean_binary_actions_impl,
    )

def _test_lean_binary_actions_impl(env, target):
    actions = target.actions

    # Should have compilation action (lean -> .olean + .c)
    compile_actions = [a for a in actions if a.mnemonic == "LeanCompile"]
    env.expect.that_int(len(compile_actions)).equals(1)

    # Should have link action (.c -> binary)
    link_actions = [a for a in actions if a.mnemonic == "LeanLink"]
    env.expect.that_int(len(link_actions)).equals(1)

    # Verify compile action has source as input
    compile_action = compile_actions[0]
    input_paths = [f.path for f in compile_action.inputs.to_list()]
    env.expect.that_collection(input_paths).contains_at_least(["Main.lean"])

def _test_lean_binary_compiler_flags(name):
    util.helper_target(
        lean_binary,
        name = name + "_subject",
        src = "Main.lean",
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        target = name + "_subject",
        impl = _test_lean_binary_compiler_flags_impl,
    )

def _test_lean_binary_compiler_flags_impl(env, target):
    actions = target.actions
    compile_action = [a for a in actions if a.mnemonic == "LeanCompile"][0]

    # Verify essential flags are present
    argv = compile_action.argv
    env.expect.that_collection(argv).contains("-c")  # Compile only
    env.expect.that_collection(argv).contains("-o")  # Output specification

def lean_binary_test_suite(name):
    test_suite(
        name = name,
        tests = [
            _test_lean_binary_produces_executable,
            _test_lean_binary_actions,
            _test_lean_binary_compiler_flags,
        ],
    )
```

#### 3. Failure tests (`rules_testing`)

Test that rules fail gracefully with invalid input.

| Test | Requirement validated | What breaks if this fails |
|------|----------------------|---------------------------|
| `test_lean_binary_missing_src` | Error when `src` not provided | Confusing error message |
| `test_lean_binary_invalid_extension` | Error for non-.lean files | Silent failure or wrong behavior |

```python
# test/unit/rules/lean_binary_failure_test.bzl
load("@rules_testing//lib:analysis_test.bzl", "analysis_test")
load("@rules_testing//lib:util.bzl", "util")
load("//lean:defs.bzl", "lean_binary")

def _test_lean_binary_invalid_extension(name):
    util.helper_target(
        lean_binary,
        name = name + "_subject",
        src = "Main.txt",  # Wrong extension
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        target = name + "_subject",
        impl = _test_lean_binary_invalid_extension_impl,
        expect_failure = True,
    )

def _test_lean_binary_invalid_extension_impl(env, target):
    env.expect.that_target(target).failures().contains_predicate(
        matching.contains(".lean")
    )
```

#### 4. Integration test (GitHub Actions)

End-to-end test that actually compiles and runs the binary.

| Test | Requirement validated | What breaks if this fails |
|------|----------------------|---------------------------|
| `bazel build //examples/02_hello_world` | Full compilation pipeline works | Users can't build Lean binaries |
| `bazel run //examples/02_hello_world` | Executable runs successfully | Built binaries don't work |
| Output verification | Correct output produced | Program logic broken |

```bash
#!/bin/bash
# .github/workflows/test-lean-binary/step-2.1-build-hello-world.sh
set -euo pipefail

cd examples/02_hello_world

# Test: Build succeeds
../../bazel build //:hello

# Test: Run succeeds and produces expected output
OUTPUT=$(../../bazel run //:hello 2>&1)
if [[ "$OUTPUT" != *"Hello, World!"* ]]; then
    echo "ERROR: Expected output to contain 'Hello, World!'"
    echo "Actual output: $OUTPUT"
    exit 1
fi

echo "✓ Hello world binary builds and runs correctly"
```

```bash
#!/bin/bash
# .github/workflows/test-lean-binary/step-2.2-test-exit-code.sh
set -euo pipefail

cd examples/02_hello_world

# Test: Exit code propagation (create a test binary that exits with code 42)
# This validates the success criterion "Exit code is propagated correctly"
../../bazel run //:exit_test && EXIT_CODE=$? || EXIT_CODE=$?
if [[ "$EXIT_CODE" != "42" ]]; then
    echo "ERROR: Expected exit code 42, got $EXIT_CODE"
    exit 1
fi

echo "✓ Exit codes propagate correctly"
```

#### Test directory structure

```
test/
├── BUILD.bazel                     # Top-level test aggregation
├── unit/
│   ├── BUILD.bazel
│   ├── rules/
│   │   ├── BUILD.bazel
│   │   ├── lean_binary_test.bzl    # Analysis tests for lean_binary
│   │   ├── lean_binary_utils_test.bzl
│   │   └── lean_binary_failure_test.bzl
│   └── toolchain/
│       ├── BUILD.bazel
│       ├── toolchain_test.bzl
│       └── toolchain_utils_test.bzl
└── fixtures/
    ├── BUILD.bazel
    ├── mock_lean.sh                # Mock lean executable for analysis tests
    └── Main.lean                   # Minimal test source file

.github/workflows/
├── test-lean-binary.yml
└── test-lean-binary/
    ├── Dockerfile
    ├── step-1.1-install-deps.sh
    ├── step-2.1-build-hello-world.sh
    └── step-2.2-test-exit-code.sh
```

---

### Phase 3: Gazelle Extension & lean_module

**Goal**: Implement a Gazelle extension that generates `lean_module` targets from Lean source files.

> **Design Note**: The Lean compiler does not support batch compilation of multiple files to multiple `.c` files. Lake handles build ordering by parsing imports and performing topological sort. Since Bazel requires action graphs at analysis time, we use Gazelle to generate explicit dependencies. See [gazelle-design.md](gazelle-design.md) for the complete design.

**Success Criteria**:
- `bazel run //:gazelle` generates `lean_module` targets for all `.lean` files
- Import extraction works via `lean --deps --json`
- Local dependencies are correctly resolved to labels
- Stdlib imports (Init, Lean, Std) are filtered out (provided by toolchain)

**New Rule - `lean_module`**:
```python
# Generated by Gazelle
lean_module(
    name = "Greeter",
    src = "Greeter.lean",
    deps = [],  # Populated by Gazelle based on imports
)
```

**Providers**:
```python
LeanModuleInfo = provider(
    fields = {
        "module_name": "Fully qualified module name",
        "olean": "The .olean file (compiled interface)",
        "ilean": "The .ilean file (incremental interface)",
        "c_source": "The generated .c file",
        "c_object": "The compiled .o file",
        "transitive_oleans": "depset of all transitive .olean files",
        "transitive_c_objects": "depset of all transitive .o files",
    },
)
```

**User Experience**:
```python
# BUILD.bazel (root)
load("@bazel_gazelle//:def.bzl", "gazelle", "gazelle_binary")

gazelle_binary(
    name = "gazelle_bin",
    languages = ["@rules_lean//gazelle:go_default_library"],
)

gazelle(
    name = "gazelle",
    gazelle = ":gazelle_bin",
)
```

```bash
# Generate BUILD files
bazel run //:gazelle
```

**Example**: `examples/03_gazelle_basic/`

**Unit Tests**:
- `lean_module` produces correct providers
- `.olean` and `.c` files are generated
- Transitive oleans are collected correctly

---

### Phase 4: Library Dependencies with Gazelle

**Goal**: Gazelle resolves imports to correct `deps` labels; binaries link against modules.

**Success Criteria**:
- Cross-file imports within a package resolve correctly
- Cross-package imports resolve to `//pkg:Module` labels
- `lean_binary` links all transitive `.o` files
- Parallel compilation of independent modules

**User Experience**:

Source files:
```lean
-- Greeter.lean
def greet (name : String) : String :=
  s!"Hello, {name}!"

-- Main.lean
import Greeter

def main : IO Unit :=
  IO.println (greet "Bazel")
```

After running `bazel run //:gazelle`:
```python
# BUILD.bazel (generated)
load("@rules_lean//lean:defs.bzl", "lean_binary", "lean_module")

lean_module(
    name = "Greeter",
    src = "Greeter.lean",
)

lean_module(
    name = "Main",
    src = "Main.lean",
    deps = [":Greeter"],
)

lean_binary(
    name = "hello",
    main = ":Main",
    deps = [":Main"],
)
```

**Example**: `examples/04_gazelle_deps/`

**Unit Tests**:
- Import resolution maps module names to labels
- Transitive dependencies are linked
- Parallel compilation works for independent modules

---

### Phase 5: Multi-Package Projects

**Goal**: Support larger projects with multiple Bazel packages.

**Success Criteria**:
- Cross-package imports resolve correctly (e.g., `import lib.Utils` → `//lib:lib.Utils`)
- Visibility is handled appropriately
- Gazelle directives allow customization (`# gazelle:lean_root`, etc.)

**User Experience**:

Directory structure:
```
lib/
├── BUILD.bazel
├── Utils.lean
└── Utils/
    └── String.lean
app/
├── BUILD.bazel
└── Main.lean
```

```lean
-- app/Main.lean
import lib.Utils
import lib.Utils.String

def main : IO Unit := ...
```

Generated `app/BUILD.bazel`:
```python
lean_module(
    name = "Main",
    src = "Main.lean",
    deps = [
        "//lib:lib.Utils",
        "//lib:lib.Utils.String",
    ],
)
```

**Gazelle Directives**:
```python
# BUILD.bazel
# gazelle:lean_root lib
# Strips "lib" prefix from module names in this directory
```

**Example**: `examples/05_multi_package/`

**Unit Tests**:
- Cross-package resolution works
- Directive parsing is correct
- Visibility constraints are respected

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

### Phase 2.5: Bazel CC Toolchain Integration

**Status**: Implemented

**Goal**: Use Bazel's registered `cc_toolchain` for compiling and linking Lean-generated C code.

This is always-on behavior. The `lean_binary` rule uses `cc_common.compile()` and `cc_common.link()` instead of Lean's bundled `leanc`.

**Action Flow**:
```
.lean --[LeanCompile]--> .c --[CppCompile]--> .o --[CppLink]--> executable
```

**Success Criteria**:
- `lean_binary` compiles using the registered CC toolchain's compiler
- Linking uses the CC toolchain's linker with Lean runtime libraries
- Binaries have minimal dynamic dependencies (no libc++.so, libgmp.so, libuv.so)
- Works with hermetic CC toolchains that provide a sysroot

**Example**: `examples/02_hello_world/`

**Documentation**: See [cc-toolchain-integration.md](cc-toolchain-integration.md) for technical details on linking, library ordering, and the `cc_common` API.

---

## Open Questions

- **Lean version pinning**: How strict should toolchain version matching be?
- **FFI support**: When/how to add C interop support?
- **Gazelle performance**: For very large codebases, should we implement lazy indexing?
- **Generated Lean files**: How should Gazelle handle imports from generated `.lean` files?
- **Lake manifest + Gazelle**: Should Gazelle read `lake-manifest.json` for external deps, or use directives only?

## Related Documents

- [gazelle-design.md](gazelle-design.md) - Detailed design for the Gazelle extension
