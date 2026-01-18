// Package lean provides a Gazelle extension for Lean 4 projects.
//
// This extension generates lean_module targets for .lean source files,
// extracting import dependencies to populate the deps attribute.
package lean

import (
	"github.com/bazelbuild/bazel-gazelle/language"
)

const languageName = "lean"

// leanLang implements the language.Language interface for Lean 4.
type leanLang struct{}

// NewLanguage creates a new Lean language extension for Gazelle.
func NewLanguage() language.Language {
	return &leanLang{}
}

// Name returns the name of the language.
func (*leanLang) Name() string {
	return languageName
}
