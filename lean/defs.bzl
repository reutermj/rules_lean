"""Public API for rules_lean."""

load("//lean:toolchain.bzl", _LeanToolchainInfo = "LeanToolchainInfo", _lean_toolchain = "lean_toolchain")
load("//lean/private:module.bzl", _LeanModuleInfo = "LeanModuleInfo", _lean_module = "lean_module")
load("//lean/private:rules.bzl", _lean_binary = "lean_binary")

lean_binary = _lean_binary
lean_module = _lean_module
lean_toolchain = _lean_toolchain
LeanModuleInfo = _LeanModuleInfo
LeanToolchainInfo = _LeanToolchainInfo
