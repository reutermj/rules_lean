"""Analysis tests for lean_binary rule."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("//lean:defs.bzl", "lean_binary")

# Test: lean_binary produces an executable output
#
# Requirement: A lean_binary target must provide DefaultInfo with an executable,
# enabling `bazel run //my:target` to work.
#
# Approach: Create a lean_binary target and use analysis_test to verify that
# DefaultInfo.files_to_run.executable is set.
#
# Why this matters: This is a Bazel contract - without it,
# `bazel run` fails with "target does not represent an executable".
def _test_lean_binary_produces_executable(name):
    lean_binary(
        name = name + "_subject",
        src = "//test/fixtures:Main.lean",
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        impl = _test_lean_binary_produces_executable_impl,
        target = name + "_subject",
    )

def _test_lean_binary_produces_executable_impl(env, target):
    default_info = target[DefaultInfo]

    # Verify executable is set
    env.expect.that_bool(
        default_info.files_to_run.executable != None,
    ).equals(True)

# Test: lean_binary registers a LeanCompile action
#
# Requirement: The rule must register a LeanCompile action that invokes the
# Lean compiler to translate .lean source to C code.
#
# Approach: Create a lean_binary target and verify exactly one action with
# mnemonic "LeanCompile" exists in the action graph.
#
# Why this matters: Without this action, Lean source files won't be compiled.
# The mnemonic also appears in build logs, helping users identify compilation steps:
#
#   $ bazel aquery //:hello --output=text | grep -E "^(action|  Mnemonic)"
#   action 'LeanCompile hello.c'
#     Mnemonic: LeanCompile
#   action 'LeanLink hello'
#     Mnemonic: LeanLink
#
#   $ bazel build //:hello --subcommands
#   SUBCOMMAND: # //:hello [action 'LeanCompile hello.c', ... mnemonic: LeanCompile]
#   SUBCOMMAND: # //:hello [action 'LeanLink hello', ... mnemonic: LeanLink]
def _test_lean_binary_has_compile_action(name):
    lean_binary(
        name = name + "_subject",
        src = "//test/fixtures:Main.lean",
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        impl = _test_lean_binary_has_compile_action_impl,
        target = name + "_subject",
    )

def _test_lean_binary_has_compile_action_impl(env, target):
    actions = target.actions

    # Find LeanCompile action
    compile_actions = [a for a in actions if a.mnemonic == "LeanCompile"]
    env.expect.that_int(len(compile_actions)).equals(1)

# Test: lean_binary registers CC compile and link actions
#
# Requirement: The rule must use the CC toolchain for compiling C code and
# linking the final executable with Lean runtime libraries.
#
# Approach: Create a lean_binary target and verify that CC toolchain actions
# exist (CppCompile for .c to .o, CppLink for linking).
#
# Why this matters: Using the CC toolchain enables cross-compilation and
# integration with other Bazel C/C++ rules.
def _test_lean_binary_has_link_action(name):
    lean_binary(
        name = name + "_subject",
        src = "//test/fixtures:Main.lean",
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        impl = _test_lean_binary_has_link_action_impl,
        target = name + "_subject",
    )

def _test_lean_binary_has_link_action_impl(env, target):
    actions = target.actions

    # Find CppLink action (from cc_common.link)
    link_actions = [a for a in actions if a.mnemonic == "CppLink"]
    env.expect.that_int(len(link_actions)).equals(1)

# Test: LeanCompile action includes source file as input
#
# Requirement: The compile action must declare the .lean source file as an input
# so Bazel tracks the dependency and rebuilds when the source changes.
#
# Approach: Create a lean_binary target, find the LeanCompile action, and verify
# the source file (Main.lean) appears in the action's input list.
#
# Why this matters: If the source isn't declared as an input, Bazel won't rebuild
# when the source changes, leading to stale outputs and confusing build behavior.
def _test_lean_binary_compile_action_has_source_input(name):
    lean_binary(
        name = name + "_subject",
        src = "//test/fixtures:Main.lean",
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        impl = _test_lean_binary_compile_action_has_source_input_impl,
        target = name + "_subject",
    )

def _test_lean_binary_compile_action_has_source_input_impl(env, target):
    actions = target.actions
    compile_actions = [a for a in actions if a.mnemonic == "LeanCompile"]

    # Should have exactly one compile action
    env.expect.that_int(len(compile_actions)).equals(1)

    compile_action = compile_actions[0]
    input_basenames = [f.basename for f in compile_action.inputs.to_list()]

    # Source file should be in inputs
    env.expect.that_collection(input_basenames).contains("Main.lean")

# Test: LeanCompile action outputs a .c file
#
# Requirement: The compile action must produce a .c file as output, which is the
# intermediate representation that gets linked into the final executable.
#
# Approach: Create a lean_binary target, find the LeanCompile action, and verify
# one of its outputs has a .c extension.
#
# Why this matters: Lean compiles to C as an intermediate step. Without the .c
# output, the link action has nothing to compile into the final executable.
def _test_lean_binary_compile_action_outputs_c_file(name):
    lean_binary(
        name = name + "_subject",
        src = "//test/fixtures:Main.lean",
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        impl = _test_lean_binary_compile_action_outputs_c_file_impl,
        target = name + "_subject",
    )

def _test_lean_binary_compile_action_outputs_c_file_impl(env, target):
    actions = target.actions
    compile_actions = [a for a in actions if a.mnemonic == "LeanCompile"]
    compile_action = compile_actions[0]

    output_extensions = [f.extension for f in compile_action.outputs.to_list()]
    env.expect.that_collection(output_extensions).contains("c")

# Test: CppLink action produces the final executable
#
# Requirement: The link action must produce an executable binary named after
# the target.
#
# Approach: Create a lean_binary target, find the CppLink action, and verify
# it produces an output whose basename matches the target name.
#
# Why this matters: This is the final artifact users care about. The output name
# must match the target name so `bazel run //:foo` executes the right binary.
def _test_lean_binary_link_action_produces_executable(name):
    lean_binary(
        name = name + "_subject",
        src = "//test/fixtures:Main.lean",
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        impl = _test_lean_binary_link_action_produces_executable_impl,
        target = name + "_subject",
    )

def _test_lean_binary_link_action_produces_executable_impl(env, target):
    actions = target.actions
    link_actions = [a for a in actions if a.mnemonic == "CppLink"]
    link_action = link_actions[0]

    # Output should include an executable named after the target
    output_basenames = [f.basename for f in link_action.outputs.to_list()]
    env.expect.that_collection(output_basenames).contains("test_lean_binary_link_action_produces_executable_subject")

# Test: Source copy preserves workspace-relative path for module naming
#
# Requirement: When copying the source file (needed for symlink workaround), the
# copy must preserve the workspace-relative path structure.
#
# Approach: Create a lean_binary with source at //test/fixtures:Main.lean, find
# the .lean output of LeanCompile, and verify its path ends with "test/fixtures/Main.lean".
#
# Why this matters: Lean derives module names from file paths relative to --root.
# For //test/fixtures:Main.lean, the module name should be "test.fixtures.Main".
# If the path structure isn't preserved, module names will be wrong.
def _test_lean_binary_preserves_source_path_for_module_naming(name):
    lean_binary(
        name = name + "_subject",
        src = "//test/fixtures:Main.lean",
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        impl = _test_lean_binary_preserves_source_path_for_module_naming_impl,
        target = name + "_subject",
    )

def _test_lean_binary_preserves_source_path_for_module_naming_impl(env, target):
    actions = target.actions
    compile_actions = [a for a in actions if a.mnemonic == "LeanCompile"]
    compile_action = compile_actions[0]

    # Find the source copy output (the .lean file in outputs)
    lean_outputs = [f for f in compile_action.outputs.to_list() if f.path.endswith(".lean")]
    env.expect.that_int(len(lean_outputs)).equals(1)

    src_copy = lean_outputs[0]

    # The path should preserve the workspace-relative structure.
    # For //test/fixtures:Main.lean, the copy should end with "test/fixtures/Main.lean"
    # This ensures the module name will be "test.fixtures.Main".
    env.expect.that_str(src_copy.short_path).contains("test/fixtures/Main.lean")

# Test: --root flag setup enables correct module name derivation
#
# Requirement: The source copy must be placed under a "_lean_src" directory such
# that the path from that directory to the source matches the workspace-relative path.
#
# Approach: Create a lean_binary, find the .lean output, verify it contains "_lean_src/"
# and that the path after "_lean_src/" exactly equals "test/fixtures/Main.lean".
#
# Why this matters: The --root flag points to the "_lean_src" directory. Lean computes
# module names as: path_from_root_to_source with "/" replaced by ".". If the path after
# "_lean_src/" doesn't match the workspace-relative path, module names will be wrong.
def _test_lean_binary_root_flag_matches_source_structure(name):
    lean_binary(
        name = name + "_subject",
        src = "//test/fixtures:Main.lean",
        tags = ["manual"],
    )

    analysis_test(
        name = name,
        impl = _test_lean_binary_root_flag_matches_source_structure_impl,
        target = name + "_subject",
    )

def _test_lean_binary_root_flag_matches_source_structure_impl(env, target):
    actions = target.actions
    compile_actions = [a for a in actions if a.mnemonic == "LeanCompile"]
    compile_action = compile_actions[0]

    # For run_shell actions, the command is in content.arguments
    # The command should contain --root= pointing to the _lean_src directory
    # We check that the command structure is correct by verifying the output paths

    # Find the source copy output
    lean_outputs = [f for f in compile_action.outputs.to_list() if f.path.endswith(".lean")]
    src_copy = lean_outputs[0]

    # The source copy should be under a "_lean_src" directory structure
    env.expect.that_str(src_copy.path).contains("_lean_src/")

    # The path after "_lean_src/" should be the workspace-relative path
    # This is what --root will use to derive the module name
    path_parts = src_copy.path.split("_lean_src/")
    env.expect.that_int(len(path_parts)).equals(2)

    workspace_relative_part = path_parts[1]
    env.expect.that_str(workspace_relative_part).equals("test/fixtures/Main.lean")

def lean_binary_test_suite(name):
    """Creates the test suite for lean_binary rule."""
    test_suite(
        name = name,
        tests = [
            _test_lean_binary_produces_executable,
            _test_lean_binary_has_compile_action,
            _test_lean_binary_has_link_action,
            _test_lean_binary_compile_action_has_source_input,
            _test_lean_binary_compile_action_outputs_c_file,
            _test_lean_binary_link_action_produces_executable,
            _test_lean_binary_preserves_source_path_for_module_naming,
            _test_lean_binary_root_flag_matches_source_structure,
        ],
    )
