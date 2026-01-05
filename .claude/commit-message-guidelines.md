# Commit Message Guidelines

This runbook describes the commit message format for the toolchains_cc project.

## Philosophy

Commit messages should focus on **why** and **what**, not **how**. The diff shows the "how"—your message should provide the context and reasoning that the diff cannot convey.

## Format

Commits use underlined headers and follow this structure:

```
<type>: <subject>

Problem
================================================================================

<description of what problem this solves or what need this addresses>

Context
================================================================================

<what is wrong with the current state of the code?>

Solution
================================================================================

<what approach does this commit take?>

Rationale
================================================================================

<why was this approach chosen?>

<optional additional sections>
================================================================================

<other sections as appropriate: Test Plan, Breaking Changes, etc.>

<optional footer: co-authors, issue references, etc.>
```

## Required Sections

### 1. Subject Line

**Format**: `<type>: <subject>`

**Types** (enforced by commitlint):
- `feat`: New feature or capability
- `fix`: Bug fix
- `docs`: Documentation changes
- `chore`: Maintenance, dependencies, tooling

**Subject Guidelines**:
- Use imperative mood ("add feature" not "added feature")
- Don't capitalize first letter after colon
- No period at the end
- Keep under 72 characters if possible

**Examples**:
- `feat: add support for musl libc 1.2.5`
- `fix: resolve linker errors with glibc 2.42`
- `docs: add runbook structure for token-efficient documentation`
- `chore: clean up GCC build scripts and documentation`

### 2. Problem Section

Explain **what problem** this commit solves or **what need** it addresses. This is the "why are we making this change?" section.

**Good examples**:
```
Problem
================================================================================

Claude Code loads CLAUDE.md on every conversation, consuming tokens even for
rarely-used content like detailed procedures. As documentation grows, this
wastes tokens and slows down conversations that don't need the detailed context.
```

```
Problem
================================================================================

Users need to build C/C++ code against musl libc for static linking, but the
toolchain currently only supports glibc targets.
```

**Bad examples**:
```
Problem
================================================================================

This commit adds a new file.
```
*(This describes "what" you did, not "why")*

```
Problem
================================================================================

The code was wrong.
```
*(Too vague—what was wrong and why does it matter?)*

### 3. Context Section

Describe **what is wrong with the current state of the code**. Use subsections in question format to organize different aspects of the problem.

**Example subsection questions**:
- What are the symptoms?
- What functionality is missing?
- What user experience is blocked?
- What performance issues exist?
- What is unclear or confusing about the current code?
- What errors or failures occur?

**Good examples**:
```
Context
================================================================================

Currently, all documentation procedures are inlined in CLAUDE.md, which is
loaded on every conversation regardless of relevance.

What performance issues exist?
--------------------------------------------------------------------------------

The "adding new toolchain configurations" procedure consumes ~200 tokens
even in conversations that never touch toolchain configuration. As more
procedures are added, this overhead will grow linearly.

What is unclear about the current code?
--------------------------------------------------------------------------------

There's no established pattern for where to put detailed procedures, leading
developers to either bloat CLAUDE.md or scatter documentation across ad-hoc
locations.
```

```
Context
================================================================================

The toolchain only supports glibc targets. Attempting to build for musl fails
at configuration time with "unsupported target triple".

What functionality is missing?
--------------------------------------------------------------------------------

Users cannot create static binaries for Alpine Linux containers or embedded
systems that require musl libc. This blocks deployment scenarios where glibc
is unavailable or undesirable.

What user experience is blocked?
--------------------------------------------------------------------------------

Workarounds require maintaining separate build systems or manually patching
the toolchain configuration, both error-prone and difficult to maintain.
```

### 4. Solution Section

Explain **what approach this commit takes** to solve the problem. Describe the key changes at a conceptual level.

**Good examples**:
```
Solution
================================================================================

Introduce a two-tier documentation structure:
- Keep frequently-used quick references in CLAUDE.md
- Move detailed procedures to docs/runbooks/ directory
- Reference runbooks from CLAUDE.md with markdown links

The "adding new toolchain configurations" procedure becomes the first runbook,
demonstrating the pattern for future documentation.
```

```
Solution
================================================================================

Add musl libc 1.2.5 as a new supported target triple (x86_64-linux-musl).

This includes:
- New entries in SUPPORT_MATRIX for musl configurations
- Release metadata and SHA256 hashes for musl toolchain binaries
- CI test coverage for musl builds
```

### 5. Rationale Section

Explain **why this approach was chosen** over alternatives. Use subsections in question format to address different design decisions.

**Example subsection questions**:
- Why use X instead of Y?
- Why this specific version/configuration?
- Why modify existing code vs. creating new code?
- Why this architecture/pattern?
- Why not [obvious alternative]?

**Good examples**:
```
Rationale
================================================================================

Why Not Git Submodules for Documentation?
--------------------------------------------------------------------------------

Git submodules add complexity and require explicit initialization. A simple
directory structure is more discoverable and requires no special git knowledge.

Why docs/runbooks/ Specifically?
--------------------------------------------------------------------------------

The "runbooks" terminology is familiar to operations teams and clearly
indicates procedural documentation. The docs/ prefix follows common
conventions and keeps the repo root clean.

Why Keep References in CLAUDE.md?
--------------------------------------------------------------------------------

Without at least a pointer in CLAUDE.md, the runbooks would be invisible
to Claude Code. The reference costs minimal tokens (~10) while ensuring
discoverability.
```

```
Rationale
================================================================================

Why Separate Target Triple Instead of Flag?
--------------------------------------------------------------------------------

Adding musl as a distinct target triple (x86_64-linux-musl) rather than
a flag maintains clean separation. This prevents accidental mixing of
glibc and musl headers/libraries, which would cause subtle runtime bugs.

Why Musl 1.2.5?
--------------------------------------------------------------------------------

This is the latest stable release as of 2024-11. Starting with the newest
version ensures modern features and security fixes. Older versions can be
added if users need them for specific compatibility requirements.

Why Not Modify Existing Toolchains?
--------------------------------------------------------------------------------

The two-phase design (eager declaration + lazy download) already supports
multiple independent toolchains. Adding musl as a new toolchain is cleaner
than conditionally modifying glibc toolchains.
```

## Optional Sections

Add additional sections as appropriate for your commit:

### Test Plan

```
Test Plan
================================================================================

- [x] Verify all existing glibc configurations still build
- [x] Build hello world with musl target
- [x] Confirm static linking with `ldd` (should show "not a dynamic executable")
- [x] Run in alpine container to verify no glibc dependencies
```

### Breaking Changes

```
Breaking Changes
================================================================================

The `toolchains_cc_libc` environment variable has been renamed to
`toolchains_cc_libc_version` to better reflect that it specifies a version
number, not a libc type (which is inferred from the target triple).

Users must update their build commands:
- Old: `--repo_env=toolchains_cc_libc=2.39`
- New: `--repo_env=toolchains_cc_libc_version=2.39`
```

### Migration Guide

```
Migration Guide
================================================================================

For users currently using custom toolchain configurations:

1. Update environment variable names in `.bazelrc` files
2. Update CI workflow files to use new variable names
3. No changes needed to BUILD files or source code
```

### Related Changes

```
Related Changes
================================================================================

This is part of a larger effort to support multiple C libraries:
- #45: Add musl support (this PR)
- #52: Add support for different glibc versions
- #60: Planned uclibc support
```

## Full Example

```
feat: add support for musl libc 1.2.5

Problem
================================================================================

Users need to build C/C++ code against musl libc for static linking and
containerized deployments, but the toolchain currently only supports
glibc targets.

Context
================================================================================

The toolchain only supports glibc targets. Attempting to build for musl
fails at configuration time with "unsupported target triple".

What functionality is missing?
--------------------------------------------------------------------------------

Users cannot create static binaries for Alpine Linux containers or embedded
systems that require musl libc. This blocks deployment scenarios where glibc
is unavailable or undesirable.

What user experience is blocked?
--------------------------------------------------------------------------------

Workarounds require maintaining separate build systems or manually patching
the toolchain configuration, both error-prone and difficult to maintain.
Static binaries are essential for minimal container images.

Solution
================================================================================

Add musl libc 1.2.5 as a new supported target triple (x86_64-linux-musl).

Changes include:
- New entries in SUPPORT_MATRIX for musl configurations
- Release metadata and SHA256 hashes for musl toolchain binaries
- CI test coverage for musl builds

Rationale
================================================================================

Why Separate Target Triple Instead of Flag?
--------------------------------------------------------------------------------

Adding musl as a distinct target triple (x86_64-linux-musl) rather than
a flag maintains clean separation. This prevents accidental mixing of
glibc and musl headers/libraries, which would cause subtle runtime bugs.

Why Musl 1.2.5?
--------------------------------------------------------------------------------

This is the latest stable release as of 2024-11. Starting with the newest
version ensures modern features and security fixes. Older versions can be
added if users need them for specific compatibility requirements.

Why Not Modify Existing Toolchains?
--------------------------------------------------------------------------------

The two-phase design (eager declaration + lazy download) already supports
multiple independent toolchains. Adding musl as a new toolchain is cleaner
than conditionally modifying glibc toolchains.

Test Plan
================================================================================

- [x] Build and test with musl 1.2.5 target
- [x] Verify static linking with `ldd` (should show "not a dynamic executable")
- [x] Run in Alpine container to verify no glibc dependencies
- [x] Confirm existing glibc configurations still work
- [x] Add musl to CI test matrix

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

## What to Avoid

❌ **Don't repeat the diff**: The code changes are visible in the diff

```
Problem
================================================================================

Changed line 42 from `foo` to `bar`.
```

❌ **Don't write implementation details**: Save those for code comments

```
Context
================================================================================

This uses a for loop to iterate over the list and calls the transform
function on each element, then appends to a new list.
```

❌ **Don't be vague**:

```
Problem
================================================================================

Things weren't working right.

Context
================================================================================

Fixed it.
```

✅ **Do separate concerns properly**:

```
Problem
================================================================================

Bazel downloads toolchain binaries even for Python-only builds, adding
5+ minutes to CI runs that don't need C/C++ compilation.

Context
================================================================================

The current implementation eagerly downloads all toolchain binaries during
the repository rule phase, before Bazel knows which languages will be used.

What performance issues exist?
--------------------------------------------------------------------------------

Python-only builds spend 5+ minutes downloading GCC and sysroot tarballs
that are never used. In polyglot repositories with frequent Python-only
changes, this wastes significant CI time and bandwidth.

Solution
================================================================================

Split toolchain setup into two phases:
- Eager declaration: Register toolchain metadata immediately
- Lazy download: Download binaries only when compilation actually occurs

Rationale
================================================================================

Why Not Download Everything Upfront?
--------------------------------------------------------------------------------

Pre-downloading simplifies the implementation but wastes resources. The
two-phase approach is more complex but essential for polyglot repositories
where different builds have different needs.

Why Repository Rules Instead of Actions?
--------------------------------------------------------------------------------

Repository rules run before the analysis phase, allowing Bazel to know
about available toolchains without downloading. Actions run too late for
toolchain resolution.
```

## Clarifying Before Writing

**CRITICAL: Before writing any commit message, ask clarifying questions to gather Context and Rationale.**

The Q&A subsection format in commit messages requires real answers, not speculation. When preparing to commit:

1. **Identify what you don't know**: What's the actual problem? Why was this approach chosen? What alternatives were considered?

2. **Ask questions before committing**: Pose the questions that will appear in the commit message and ask the user to confirm, deny, or provide different answers

3. **Provide default answers when possible**: If you have a reasonable guess, offer it for confirmation (e.g., "I think we chose X over Y because of performance - is that correct?")

4. **Don't speculate in the commit**: The commit message should contain facts and decisions, not guesses about what might have been the reasoning

**Example pre-commit dialogue**:
```
Before I create the commit, I have some questions for the Context and Rationale sections:

Context Questions:
- What functionality is currently missing? [I believe users can't build for Alpine Linux - is that the main blocker?]
- What performance issues exist? [Are there any, or is this purely about functionality?]

Rationale Questions:
- Why use a separate target triple instead of a flag? [My guess: to prevent mixing glibc/musl headers]
- Why start with musl 1.2.5 specifically? [Is it just because it's the latest, or are there other reasons?]
- Were there other approaches considered? [What alternatives did you evaluate?]
```

## Tips for Writing Good Commit Messages

1. **Write for future maintainers**: Someone (including future you) will read this commit in 6 months trying to understand why a decision was made

2. **Use question format for subsections**: Questions like "What functionality is missing?" or "Why X instead of Y?" make the structure immediately clear and guide the reader

3. **Answer the question "why this approach?"**: If there were alternative solutions, briefly explain why you chose this one

4. **Include relevant context**: Benchmark numbers, error messages, compatibility requirements, or architectural constraints

5. **Link to related issues/PRs**: Use `#123` notation for GitHub integration

6. **Use underlined headers**: Section headers (80 `=`) and subsection headers (`-`) make messages scannable in plain text

7. **Be concise but complete**: Every sentence should add value, but don't leave out important context

8. **Ask questions before writing**: Never speculate about context or rationale - ask the user to confirm your understanding first

## Commit Message Checklist

Before committing, verify:

- [ ] **Asked clarifying questions** about Context and Rationale before writing the commit
- [ ] Subject line follows `<type>: <subject>` format
- [ ] **Problem** section explains why this change is needed
- [ ] **Context** section describes what's wrong with current code (symptoms, missing functionality, blocked UX, performance issues, unclear code) - based on user confirmation, not speculation
- [ ] **Solution** section explains what approach this commit takes
- [ ] **Rationale** section explains why this approach was chosen - based on user confirmation, not speculation
- [ ] Subsections used when multiple points exist in any section
- [ ] Focus is on "why" and "what", not "how"
- [ ] Underlined headers used for readability (80 `=` for sections, `-` for subsections)
- [ ] Message will make sense to someone 6 months from now
- [ ] No implementation details that belong in code comments
- [ ] No speculation or guesses - all Context and Rationale answers are factual

## Tools

The repository uses commitlint to enforce the subject line format. See [.commitlintrc.js](../../.commitlintrc.js) for the configuration.
