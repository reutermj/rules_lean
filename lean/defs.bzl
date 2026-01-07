"""Public API for rules_lean."""

load("//lean:toolchain.bzl", _LeanToolchainInfo = "LeanToolchainInfo", _lean_toolchain = "lean_toolchain")
load("//lean/private:rules.bzl", _lean_binary = "lean_binary")

lean_binary = _lean_binary
lean_toolchain = _lean_toolchain
LeanToolchainInfo = _LeanToolchainInfo
