# Lake Build Order Resolution: Topological Ordering Analysis

This document analyzes how Lake (Lean's build system) performs topological ordering of Lean files for build order resolution within a single package.

---

## High-Level Architecture

Lake uses a **post-order depth-first search (DFS)** algorithm with **memoization** to determine build order. The core idea is simple: visit all dependencies before the module itself.

---

## Key Components

### 1. Import Extraction

**File:** `src/lake/Lake/Build/Module.lean` (lines 29-42)

Lake parses imports from Lean source files using `Lean.parseImports'`:

```lean
let contents ← IO.FS.readFile path
let header ← Lean.parseImports' contents path.toString
let imports ← header.imports.mapM fun imp => do
  return ⟨imp, (← findModule? imp.module)⟩
```

This gives the direct dependencies of each file.

---

### 2. The Core Topological Sort Algorithm

**File:** `src/lake/Lake/Build/Library.lean` (lines 30-49)

The main algorithm is a classic **post-order DFS**:

```lean
private partial def LeanLib.recCollectLocalModules
  (self : LeanLib) : FetchM (Job (Array Module))
:= ensureJob do
  let mut mods := #[]
  let mut modSet := ModuleSet.empty
  for mod in (← self.getModuleArray) do
    (mods, modSet) ← go mod mods modSet
  return Job.pure mods
where
  go root mods modSet := do
    let mut mods := mods
    let mut modSet := modSet
    unless modSet.contains root do        -- Skip if already visited
      modSet := modSet.insert root        -- Mark as visited
      let imps ← (← root.imports.fetch).await
      for mod in imps do                  -- Visit all dependencies first
        if mod.lib.name = self.name then
          (mods, modSet) ← go mod mods modSet
      mods := mods.push root              -- Add module AFTER its dependencies
    return (mods, modSet)
```

**Key properties:**
- Modules appear in the result **after** all their dependencies
- Each module appears exactly **once** (via the `modSet` visited check)
- Only processes modules within the same library/package

---

### 3. Cycle Detection

**File:** `src/lake/Lake/Util/Cycle.lean` (lines 80-87)

Lake detects cycles by maintaining a call stack during traversal:

```lean
@[inline] public def guardCycle
  [BEq κ] [Monad m] [MonadCycle κ m] (key : κ) (act : m α)
: m α := do
  let parents ← getCallStack
  if parents.contains key then
    throwCycle <| key :: (parents.partition (· != key)).1 ++ [key]
  else
    withCallStack (key :: parents) act
```

The `parents` list tracks the current path being traversed. If we encounter a key already in the path, we've found a cycle.

---

### 4. Memoization / Build Store

**File:** `src/lake/Lake/Util/Store.lean` (lines 47-55)

Results are cached to avoid recomputation:

```lean
@[inline] public def fetchOrCreate
  [Monad m] (key : κ) [MonadStore1Of key α m] (create : m α)
: m α := do
  if let some val ← fetch? key then
    return val                   -- Return cached result
  else
    let val ← create             -- Compute
    store key val                -- Cache
    return val
```

The build store is a dependent tree map that maps `BuildKey` to `Job (BuildData key)`:

**File:** `src/lake/Lake/Build/Store.lean` (lines 25-32)

```lean
public abbrev BuildStore :=
  Std.DTreeMap BuildKey (Job <| BuildData ·) BuildKey.quickCmp
```

---

## Data Structures

### Build Keys

**File:** `src/lake/Lake/Build/Key.lean` (lines 19-25)

```lean
public inductive BuildKey
| module (module : Name)
| package (package : Name)
| packageModule (package module : Name)
| packageTarget (package target : Name)
| facet (target : BuildKey) (facet : Name)
```

Unique identifier for any buildable element.

### Module Representation

**File:** `src/lake/Lake/Config/Module.lean` (lines 18-29)

```lean
public structure Module where
  lib : LeanLib
  name : Name
```

Modules are looked up via `LeanLib.findModule?` and discovered via glob patterns in `LeanLib.getModuleArray`.

---

## Recursive Build Framework

**File:** `src/lake/Lake/Build/Topological.lean` (lines 76-123)

Lake uses the "Suspending Recursive Builder" pattern from *Build systems à la carte*:

```lean
public def recFetch
  [(α : Type u) → Nonempty (m α)] (fetch : DRecFetchFn α β m)
: DFetchFn α β m := fun a => fetch a |>.run (recFetch fetch)
```

With cycle detection:

```lean
public def recFetchAcyclic
  [BEq κ] [Monad m] [MonadCycle κ m]
  (keyOf : α → κ) (fetch : DRecFetchFn α β m)
: DFetchFn α β m :=
  recFetch fun a => .mk fun recurse => guardCycle (keyOf a) do
    let stack ← getCallStack
    fetch a |>.run fun a => withCallStack stack (recurse a)
```

And memoization:

```lean
public def recFetchMemoize
  [BEq κ] [Monad m] [MonadCycle κ m] [MonadDStore κ β m]
  (keyOf : α → κ) (compute : DRecFetchFn α (fun a => β (keyOf a)) m)
: DFetchFn α (fun a => β (keyOf a)) m :=
  inline <| recFetchAcyclic keyOf fun a =>
    fetchOrCreate (keyOf a) (compute a)
```

---

## Dynlib/Library Topological Sort

**File:** `src/lake/Lake/Build/Module.lean` (lines 169-186)

For dynamic library ordering, Lake uses a similar DFS with explicit cycle detection:

```lean
private partial def mkLoadOrder (libs : Array Dynlib) : FetchM (Array Dynlib) := do
  let r := libs.foldlM (m := Except (Cycle String)) (init := ({}, #[])) fun (v, o) lib =>
    go lib [] v o
  match r with
  | .ok (_, order) => pure order
  | .error cycle => error s!"library dependency cycle:\n{formatCycle cycle}"
where
  go lib (ps : List String) (v : Std.TreeSet String compare) (o : Array Dynlib) := do
    if v.contains lib.name then
      return (v, o)
    if ps.contains lib.name then
      throw (lib.name :: ps)
    let ps := lib.name :: ps
    let v := v.insert lib.name
    let (v, o) ← lib.deps.foldlM (init := (v, o)) fun (v, o) lib =>
      go lib ps v o
    let o := o.push lib
    return (v, o)
```

---

## Order of Operations

1. **Initial Request** → `Workspace.runFetchM` (`Run.lean:233`)

2. **Recursive Building** → `recBuildWithIndex` (`Index.lean:29`)
   - Checks build store for memoized result
   - If found, returns immediately
   - If not found, proceeds to compute

3. **Fetch Computation** → `FetchM` monad (`Fetch.lean:85-86`)
   - Sets up context with cycle detection and memoization
   - Invokes recursive build function

4. **Module Topological Sort** → `LeanLib.recCollectLocalModules` (`Library.lean:30`)
   - DFS traversal of import graph
   - Post-order: Modules after their dependencies
   - Memoization prevents duplicate processing

5. **Dependency Computation** → `Module.recFetchSetup` (`Module.lean:496`)
   - Fetches all dependencies for each module
   - Uses same recursive mechanism

6. **Job Execution** → Async tasks spawned as dependencies ready
   - Monitored by `monitorJobs` (`Run.lean:197`)
   - Results stored in `BuildStore` for memoization

---

## Key Files Reference

| Concept | File | Lines |
|---------|------|-------|
| Build entry point | `src/lake/Lake/Build/Run.lean` | 233-300 |
| Build keys | `src/lake/Lake/Build/Key.lean` | 19-25 |
| Module definition | `src/lake/Lake/Config/Module.lean` | 18-29 |
| Module DFS topo sort | `src/lake/Lake/Build/Library.lean` | 30-49 |
| Dynlib topo sort | `src/lake/Lake/Build/Module.lean` | 169-186 |
| Import parsing | `src/lake/Lake/Build/Module.lean` | 29-42 |
| Direct imports | `src/lake/Lake/Build/Module.lean` | 54-63 |
| Transitive imports | `src/lake/Lake/Build/Module.lean` | 96-108 |
| Recursive build framework | `src/lake/Lake/Build/Topological.lean` | 76-123 |
| Build index integration | `src/lake/Lake/Build/Index.lean` | 28-66 |
| Fetch-or-create | `src/lake/Lake/Util/Store.lean` | 47-55 |
| Cycle detection | `src/lake/Lake/Util/Cycle.lean` | 80-87 |
| Build store | `src/lake/Lake/Build/Store.lean` | 25-32 |
| Monad stack | `src/lake/Lake/Build/Fetch.lean` | 46-72 |

---

## For Porting/Reimplementation

If you're building something similar, the essential pieces are:

1. **Import parser** - extract `import` statements from each `.lean` file
2. **Module graph** - map each module to its direct dependencies
3. **Post-order DFS** - visit dependencies before dependents
4. **Visited set** - avoid processing the same module twice
5. **Cycle detection** - track the current path to detect circular imports

The algorithm itself is straightforward—the complexity in Lake comes from:
- Handling external packages and workspaces
- Incremental builds and caching
- Parallel execution with async jobs
- Multiple "facets" (olean, c, dynlib, etc.)

For a single-package case without external dependencies, a simple implementation would be ~50-100 lines of code.

---

## Minimal Pseudocode

```
function topologicalSort(allModules):
    visited = {}
    result = []

    for each module in allModules:
        visit(module, visited, result)

    return result

function visit(module, visited, result):
    if module in visited:
        return

    visited.add(module)

    for each import in module.imports:
        visit(import, visited, result)

    result.append(module)  // Post-order: add AFTER dependencies
```

With cycle detection:

```
function visit(module, visited, currentPath, result):
    if module in currentPath:
        throw CycleError(currentPath + [module])

    if module in visited:
        return

    currentPath.push(module)
    visited.add(module)

    for each import in module.imports:
        visit(import, visited, currentPath, result)

    currentPath.pop()
    result.append(module)
```

---

## Querying Build/Dependency Information

Both Lean's compiler and Lake provide ways to extract dependency information in structured formats.

### Lean Compiler Options

The Lean compiler can directly output dependency information without performing a full build.

**File:** `src/Lean/Shell.lean` (lines 176-177, 381-386)

#### `--deps` — Print olean paths (single file)

```bash
lean --deps MyModule.lean
```

Outputs the `.olean` file path for each direct import, one per line. Only accepts a single file.

#### `--src-deps` — Print source file paths (single file)

```bash
lean --src-deps MyModule.lean
```

Outputs the `.lean` source file path for each direct import. Only accepts a single file.

#### `--deps --json` — Batch mode (multiple files)

```bash
lean --deps --json file1.lean file2.lean file3.lean
# or via stdin:
echo -e "file1.lean\nfile2.lean" | lean --deps --json --stdin
```

This is the only mode that accepts multiple files. Results are returned in a single JSON object.

**File:** `src/Lean/Elab/ParseImportsFast.lean` (lines 256-272)

Output structure:

```json
{
  "imports": [
    {
      "result": {
        "imports": [
          {"module": "Init.Core", "importAll": false, "isExported": true, "isMeta": false},
          {"module": "Mathlib.Algebra", "importAll": false, "isExported": true, "isMeta": false}
        ],
        "isModule": true
      }
    }
  ]
}
```

The `Import` structure (**File:** `src/Lean/Setup.lean`, lines 25-33):

| Field | Type | Description |
|-------|------|-------------|
| `module` | `Name` | The module name being imported |
| `importAll` | `Bool` | Whether using `import all` syntax |
| `isExported` | `Bool` | Whether the import is re-exported (not `private import`) |
| `isMeta` | `Bool` | Whether using `meta import` for transitive IR |

**Note:** These commands return **direct imports only**, not transitive dependencies.

---

### Lake Query Command

Lake provides the `lake query` command to extract build information with optional JSON output.

**File:** `src/lake/Lake/CLI/Main.lean` (lines 625-635)

#### Basic Usage

```bash
lake query <target>           # Plain text output
lake query <target> --json    # JSON output
lake query <target> -J        # JSON output (short form)
```

#### Available Facets

**Module facets** (query with `+ModuleName:facet`):

| Facet | Description | Example |
|-------|-------------|---------|
| `imports` | Direct local imports | `lake query +A:imports` → `B` |
| `transImports` | Transitive local imports | `lake query +A:transImports --json` → `["C","B"]` |
| `precompileImports` | Precompile import dependencies | |
| `olean` | Path to `.olean` file | |
| `ilean` | Path to `.ilean` file | |
| `c` | Path to generated C file | |
| `o` | Path to object file | |

**Library facets** (query with `libName:facet`):

| Facet | Description | Example |
|-------|-------------|---------|
| `modules` | All modules in the library | `lake query lib:modules` |

**Package facets** (query with `pkgName:facet`):

| Facet | Description | Example |
|-------|-------------|---------|
| `deps` | Direct package dependencies | `lake query myPkg:deps --json` |
| `transDeps` | Transitive package dependencies | `lake query myPkg:transDeps --json` |

#### Examples

```bash
# Get direct imports of module A
lake query +A:imports
# Output: B

# Get transitive imports as JSON
lake query +A:transImports --json
# Output: ["C","B"]

# Get all modules in a library
lake query lib:modules

# Query multiple targets
lake query foo bar

# Get executable path (can be executed directly)
$(lake query myExe)
```

**File:** `tests/lake/tests/query/test.sh` contains more examples.

---

### Building a Complete Build Order

Neither tool directly exports the full topological build order. To construct it:

#### Option 1: Using Lean's `--deps --json`

```bash
#!/bin/bash
# Collect all .lean files and their imports, then topologically sort

# Get imports for all files
find . -name "*.lean" | xargs lean --deps --json > imports.json

# Parse JSON and build dependency graph, then toposort
# (requires custom script to process the JSON)
```

#### Option 2: Using Lake's query command

```bash
#!/bin/bash
# Get all modules in the library
modules=$(lake query lib:modules)

# For each module, get its transitive imports
for mod in $modules; do
  deps=$(lake query "+$mod:transImports" --json)
  echo "{\"module\": \"$mod\", \"deps\": $deps}"
done
```

#### Option 3: Programmatic access via Lean

Use `Lean.parseImports'` directly in Lean code:

```lean
import Lean.Elab.ParseImportsFast

def getImports (path : System.FilePath) : IO (Array Lean.Import) := do
  let contents ← IO.FS.readFile path
  let header ← Lean.parseImports' contents path.toString
  return header.imports
```

---

### Key Files Reference (Querying)

| Concept | File | Lines |
|---------|------|-------|
| Lean `--deps` implementation | `src/Lean/Elab/Import.lean` | 92-103 |
| Lean `--deps --json` implementation | `src/Lean/Elab/ParseImportsFast.lean` | 265-272 |
| Fast import parser | `src/Lean/Elab/ParseImportsFast.lean` | 248-254 |
| Import structure | `src/Lean/Setup.lean` | 25-33 |
| ModuleHeader structure | `src/Lean/Setup.lean` | 43-48 |
| Lake `query` command | `src/lake/Lake/CLI/Main.lean` | 625-635 |
| Lake output formatting | `src/lake/Lake/Config/OutFormat.lean` | — |
| Lake builtin facets | `src/lake/Lake/Build/Infos.lean` | 78-99 |
| Lake query tests | `tests/lake/tests/query/test.sh` | — |
