# rules_lean

## Guidelines

* **DO NOT** commit directly to the main branch; **YOU MUST** create a new feature branch for all changes

## Runbooks

Runbooks are detaild procedures for use in a specific context.
**When a runbook's context occurs, YOU MUST ALWAYS read the runbook BEFORE taking any action.**

- **BEFORE creating any commit, YOU MUST read**: .claude/commit-message-guidelines.md

## Comment Philosophy

**ALWAYS follow these guidelines when writing or modifying code comments.**

### Core Principles

1. **Inline comments answer "why?"** - Why this choice? Why this workaround? Why this optimization?
2. **Doc comments answer "what?"** - What does this function/class do? What's the API?
3. **Code answers "how?"** - Through clear naming, good factoring, and self-documenting structure
4. **Commit messages provide rationale** - Longer explanations of design decisions
5. **Links are valuable** - Point to issues, bug trackers, docs, RFCs, etc.

### Good Reasons for Inline Comments

- Workarounds for bugs in dependencies
- Non-obvious constraints from external systems
- Performance optimizations that might seem unusual
- Design tradeoffs that aren't obvious from the code

### Links and References

**Link format:**
- **Current repo GitHub issues:** Use short form `#1234`
- **External issues/bugs:** Use full URL `https://github.com/org/repo/issues/1234`
- **Current repo docs:** Use relative path from repo root `docs/architecture.md`
- **External docs:** Use full URL `https://sourceware.org/glibc/wiki/ABICompatibility`

### Examples

**Good - Dependency workaround:**
```python
# Bazel requires explicit include paths for cross-compilation
# See: https://github.com/bazelbuild/bazel/issues/12345
builtin_include_dirs = [...]
```

**Good - Platform-specific workaround:**
```c++
#ifdef __GLIBC__
// Prevent RSS bloat in long-running processes
// https://sourceware.org/bugzilla/show_bug.cgi?id=11261
malloc_trim(0);
#endif
```

**Good - Performance optimization:**
```python
# Cache lookups because toolchain resolution is expensive
# (involves filesystem scanning and version parsing)
if target_triple in _cache:
    return _cache[target_triple]
```

**Bad - Explains "what?" (obvious):**
```c++
// Calculate the sum of two numbers
int add(int a, int b) { return a + b; }
```

### Before Adding "How?" Comments

Try these alternatives first:
1. Rename variables/functions to be more descriptive
2. Extract complex expressions into named variables
3. Break complex logic into smaller, well-named functions

If code truly requires a "how?" explanation despite refactoring attempts, add the comment. Don't let the code remain obscure.
