# CC Toolchain Integration

This document describes how `rules_lean` integrates with Bazel's CC toolchain for compiling and linking Lean-generated C code.

## Overview

The `lean_binary` rule uses Bazel's registered `cc_toolchain` instead of Lean's bundled `leanc` compiler wrapper. This is always-on behavior that provides:

- **Hermetic builds**: Consistent sysroot across the entire build
- **Reproducibility**: Works with hermetic CC toolchains (e.g., `toolchains_cc`)
- **Polyglot integration**: Shared toolchain configuration across Lean and C/C++ code
- **Flexibility**: Use platform-specific compilers or organizational toolchains

## Action Flow

```
.lean --[LeanCompile]--> .c --[CppCompile]--> .o --[CppLink]--> executable
```

1. **LeanCompile**: The Lean compiler (`lean`) compiles `.lean` source to C code
2. **CppCompile**: The CC toolchain compiles the generated `.c` to object files
3. **CppLink**: The CC toolchain links object files with Lean runtime libraries

## Lean Distribution Structure

The Lean distribution provides headers and libraries needed for compilation and linking:

```
lean-{version}-{platform}/
├── include/
│   └── lean/              # Lean runtime headers (lean.h, config.h, etc.)
├── lib/
│   └── lean/              # Lean runtime libraries
│       ├── libInit.a      # Initialization
│       ├── libLean.a      # Core Lean runtime
│       ├── libleancpp.a   # C++ runtime bridge
│       ├── libleanrt.a    # Low-level runtime
│       └── libStd.a       # Standard library
└── lib/                   # Support libraries
    ├── libc++.a           # libc++ (clang C++ standard library)
    ├── libc++abi.a        # libc++ ABI support
    ├── libgmp.a           # GNU Multiple Precision Arithmetic
    └── libuv.a            # Async I/O library
```

## Linking Details

Linking Lean binaries requires careful attention to library ordering and static/dynamic linking.

### Library Search Paths

Two `-L` paths are needed:
- `lib/lean/` - Lean runtime libraries
- `lib/` - Support libraries (libc++, libgmp, libuv)

### Circular Dependency Handling

Lean libraries have mutual dependencies. The linker's `--start-group/--end-group` flags tell it to iterate until all symbols resolve:

```
-Wl,--start-group -lleancpp -lLean -Wl,--end-group
-lStd
-Wl,--start-group -lInit -lleanrt -Wl,--end-group
```

Without grouping, link order would matter and some symbols might not be found. For example, `libleancpp.a` calls into `libLean.a` and vice versa.

### libc++ ABI Requirement

Lean's `libleancpp.a` is compiled with clang/libc++ and uses the libc++ ABI (`std::__1::` namespace). We must link against the libc++ from Lean's distribution, not the system's libstdc++:

```
-Wl,-Bstatic -lc++ -lc++abi
```

The `-Bstatic` flag forces static linking for these specific libraries, ensuring the binary doesn't depend on system `libc++.so` at runtime.

### Static Support Libraries

GMP (arbitrary precision arithmetic) and libuv (async I/O) are bundled with Lean. We link them statically to avoid runtime dependencies:

```
-Wl,-Bstatic -lgmp -luv -Wl,-Bdynamic
```

The `-Bdynamic` at the end restores default behavior for subsequent libraries.

### System Libraries

Standard system libraries are linked dynamically:

```
-lm -lpthread -ldl -lrt
```

### Complete Link Flag Order

```
# Library search paths
-L{lean_lib_dir}
-L{support_lib_dir}

# Lean runtime (with circular dependency handling)
-Wl,--start-group -lleancpp -lLean -Wl,--end-group
-lStd
-Wl,--start-group -lInit -lleanrt -Wl,--end-group

# Static C++ runtime from Lean distribution
-Wl,-Bstatic -lc++ -lc++abi

# Static support libraries from Lean distribution
-lgmp -luv -Wl,-Bdynamic

# System libraries (dynamic)
-lm -lpthread -ldl -lrt
```

## cc_common API Usage

The implementation uses Bazel's `cc_common` Starlark module:

### Compilation

```starlark
_compilation_context, compilation_outputs = cc_common.compile(
    actions = ctx.actions,
    feature_configuration = feature_configuration,
    cc_toolchain = cc_toolchain,
    srcs = [c_file],
    includes = [lean_toolchain.lean_include],
    additional_inputs = lean_toolchain.headers.to_list(),
    name = name,
    user_compile_flags = ["-Wno-unused-variable"],
)
```

- `includes`: Directory path for `-I` flag (Lean headers)
- `additional_inputs`: Header files that must be available in the sandbox
- `user_compile_flags`: `-Wno-unused-variable` suppresses warnings from Lean-generated C code

### Linking

```starlark
linking_outputs = cc_common.link(
    actions = ctx.actions,
    feature_configuration = feature_configuration,
    cc_toolchain = cc_toolchain,
    compilation_outputs = compilation_outputs,
    output_type = "executable",
    name = name,
    user_link_flags = link_flags,
    additional_inputs = lean_toolchain.libs.to_list(),
)
```

- `user_link_flags`: Passed to the linker command line (-L paths and -l libraries)
- `additional_inputs`: The `.a` files must be declared here so Bazel makes them available in the sandbox during linking

## Toolchain Provider Fields

The `LeanToolchainInfo` provider exposes:

| Field | Description |
|-------|-------------|
| `lean_include` | Path to include directory for `-I` flag |
| `lean_lib` | Path to `lib/lean/` for `-L` flag |
| `support_lib` | Path to `lib/` for `-L` flag |
| `headers` | Depset of header files for `additional_inputs` |
| `libs` | Depset of library files for `additional_inputs` |

## Hermetic CC Toolchains

For fully reproducible builds, use a hermetic CC toolchain that provides its own sysroot:

```python
# MODULE.bazel
bazel_dep(name = "toolchains_cc")
git_override(
    module_name = "toolchains_cc",
    commit = "...",
    remote = "https://github.com/user/toolchains_cc",
)
register_toolchains("@toolchains_cc")
```

To verify hermetic toolchain usage, inspect build commands:

```bash
bazel build //:hello -s 2>&1 | grep -E '(gcc|clang|sysroot)'
```

The output should show the compiler path contains the toolchain name and includes a `--sysroot` flag.

## Binary Characteristics

A correctly linked Lean binary should have minimal dynamic dependencies:

**Expected** (system libraries):
- `libc.so` - Standard C library
- `libm.so` - Math library
- `libpthread.so` - POSIX threads
- `libdl.so` - Dynamic linking
- `librt.so` - Real-time extensions

**Forbidden** (should be statically linked):
- `libc++.so` - Must use static libc++ from Lean
- `libgmp.so` - Must use static libgmp from Lean
- `libuv.so` - Must use static libuv from Lean
- `liblean*.so` - No Lean shared libraries

Verify with `ldd`:

```bash
ldd bazel-bin/hello
```

## Tests

Integration tests in `examples/02_hello_world/` verify correct behavior:

- **verify_static_linking_test**: Checks that forbidden dynamic dependencies are not present
- **verify_hermetic_toolchain_test**: Documents binary characteristics for debugging
