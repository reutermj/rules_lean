# Repository Rule Dependency Resolution

## The Problem

Lean compilation requires modules to be compiled in dependency order.
All imported modules must produce `.olean` files before the importing module can compile. 
This is fundamentally a two-phase process:

1. **Parse imports** to discover dependencies
2. **Compile in order** according to the dependency graph

### Why This Is Hard in Bazel

Bazel fixes the action graph during the analysis phase where the source files are not readable.
During the execution phase when the source files are readable, the action graph can no longer be modified.

This means a naive approach works:

```python
lean_binary(
    name = "mylib",
    srcs = ["A.lean", "B.lean", "C.lean"],
)
```

But this approach requires recompiling all lean files in a single action.
This loses out on incremental recompilation and distributed builds.

---

## The Solution: Repository Rules

Repository rules execute during the **loading phase**—before analysis. They can read files, execute programs, and generate BUILD files. This lets us parse imports and generate explicit dependency declarations before Bazel needs them.

### How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                        MODULE.bazel                                 │
│  lean.toolchain(version = "4.27.0")                                 │
│  lean.project(name = "mylib", root = "src")                         │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Repository Rule (loading phase)                  │
│                                                                     │
│  1. Find all .lean files in project                                 │
│  2. Run `lean --deps` to extract imports                            │
│  3. Build dependency graph, detect cycles                           │
│  4. Generate BUILD.bazel with lean_module targets                   │
│                                                                     │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│              Generated BUILD.bazel (external repository)            │
│                                                                     │
│  lean_module(name = "Core", src = "Core.lean", deps = [])           │
│  lean_module(name = "Utils", src = "Utils.lean", deps = [":Core"])  │
│  lean_module(name = "App", src = "App.lean", deps = [":Utils"])     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

The generated external repository contains explicit `lean_module` targets with resolved dependencies. Bazel's analysis phase can now process these normally.

---

## User Experience

### Configuration

```python
# MODULE.bazel
bazel_dep(name = "rules_lean", version = "0.1.0")

lean = use_extension("@rules_lean//lean:extensions.bzl", "lean")
lean.toolchain(version = "4.27.0")
lean.project(
    name = "mylib",
    root = "src",  # Directory containing .lean files
)
use_repo(lean, "lean_toolchain_linux_x86_64", "mylib")
```

### Usage

```python
# BUILD.bazel
load("@rules_lean//lean:defs.bzl", "lean_binary")

lean_binary(
    name = "app",
    src = "Main.lean",
    deps = ["@mylib//:Utils.Math"],  # Reference generated module
)
```

### Example Project Structure

```
workspace/
├── MODULE.bazel
├── BUILD.bazel
└── src/
    ├── Core.lean           # imports nothing
    ├── Utils/
    │   ├── Math.lean       # imports Core
    │   └── String.lean     # imports Core
    └── App.lean            # imports Utils.Math, Utils.String
```

The `lean.project` declaration scans `src/`, discovers the import relationships, and generates:

```python
# @mylib//:BUILD.bazel (auto-generated)
lean_module(name = "Core", src = "Core.lean", deps = [])
lean_module(name = "Utils.Math", src = "Utils/Math.lean", deps = [":Core"])
lean_module(name = "Utils.String", src = "Utils/String.lean", deps = [":Core"])
lean_module(name = "App", src = "App.lean", deps = [":Utils.Math", ":Utils.String"])
```

---

## Key Design Decisions

### Using `lean --deps` for Import Parsing

Rather than implementing a custom parser, we use Lean's built-in `--deps` flag:

```bash
$ lean --deps Main.lean
/path/to/lean/lib/lean/Init.olean
/path/to/project/Utils/Math.olean
```

This outputs expected `.olean` paths for all imports.
The repository rule filters these paths to identify local dependencies (under the project root) vs stdlib dependencies (handled by the toolchain).

### LEAN_PATH and Module Resolution

`LEAN_PATH` is an environment variable that tells the Lean compiler where to find `.olean` files when resolving `import` statements. It works like Unix `PATH`—a colon-separated list of directories to search.

When compiling `import Utils.Math`, Lean looks for `Utils/Math.olean` in each `LEAN_PATH` directory. The rules compute `LEAN_PATH` from dependency `.olean` locations:

```
# If Utils.Math compiles to:
bazel-out/k8-fastbuild/bin/external/mylib/Utils/Math.olean

# Then LEAN_PATH includes:
bazel-out/k8-fastbuild/bin/external/mylib

# So `import Utils.Math` resolves to:
bazel-out/k8-fastbuild/bin/external/mylib/Utils/Math.olean
```

### Host vs Execution Toolchain

Repository rules run on the developer's local machine during the loading phase and before Bazel's toolchain resolution.
As well, the local machine is not necessarily the same platform as the build worker in the case of remote execution.

The module extension explicitly declares all supported toolchains for a particular version.
It then detects the host platform and explicitly wires locally compatible `lean` binary to the `lean_project` repository rule.
This works because the dependency graph discovered by `--deps` is platform-independent.
Bazel's toolchain resolution kicks in at the execution phase and selects the right lean toolchain for compilation.

---

## Rules Overview

### `lean_module`

Compiles a single `.lean` file, producing:
- `.olean` file (for downstream Lean compilation)
- `.c` file (intermediate)
- `.o` file (for linking)

Provides `LeanModuleInfo` containing transitive dependencies for downstream rules.

### `lean_binary`

Compiles a main `.lean` file and links with module dependencies:

```python
lean_binary(
    name = "app",
    src = "Main.lean",
    deps = ["@mylib//:Utils.Math", "@mylib//:Utils.String"],
)
```

Collects transitive `.olean` files for compilation and transitive `.o` files for linking.

### `lean_project` (Repository Rule)

Scans a directory for `.lean` files, discovers dependencies via `lean --deps`, and generates a BUILD file with `lean_module` targets.

---

## Caching and Invalidation

The repository rule re-executes when:
- Any `.lean` file in the project changes
- The `MODULE.bazel` configuration changes
- The repository rule implementation changes

Bazel handles this automatically through its repository rule invalidation mechanism.
