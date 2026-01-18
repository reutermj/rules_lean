"""Gazelle support for Lean projects.

Use the pre-built gazelle binary at @rules_lean//gazelle:gazelle_bin:

    load("@gazelle//:def.bzl", "gazelle")

    gazelle(
        name = "gazelle",
        gazelle = "@rules_lean//gazelle:gazelle_bin",
    )

Then run: bazel run //:gazelle
"""

# The gazelle binary is defined at //gazelle:gazelle_bin
GAZELLE_BIN = "@rules_lean//gazelle:gazelle_bin"
