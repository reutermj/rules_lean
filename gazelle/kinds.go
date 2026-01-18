package lean

import (
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// Kinds implements language.Language.
// Returns metadata about the rule kinds this extension can generate.
func (*leanLang) Kinds() map[string]rule.KindInfo {
	return map[string]rule.KindInfo{
		"lean_module": {
			// NonEmptyAttrs: attributes that prevent rule deletion if present
			// If src is empty, the rule should be deleted
			NonEmptyAttrs: map[string]bool{
				"src": true,
			},
			// MergeableAttrs: attributes that should be merged from existing rules
			// The deps attribute is managed by Gazelle and should be merged
			MergeableAttrs: map[string]bool{
				"deps": true,
			},
		},
		"lean_binary": {
			NonEmptyAttrs: map[string]bool{
				"main": true,
			},
			MergeableAttrs: map[string]bool{
				"deps": true,
			},
		},
	}
}
