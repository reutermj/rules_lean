package lean

import (
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/language"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// GenerateRules implements language.Language.
// It finds all .lean files in the directory and generates lean_module targets.
func (l *leanLang) GenerateRules(args language.GenerateArgs) language.GenerateResult {
	cfg := GetLeanConfig(args.Config)

	// Find all .lean files in this directory (not subdirectories)
	leanFiles := findLeanFiles(args.Dir, args.RegularFiles, cfg)
	if len(leanFiles) == 0 {
		return language.GenerateResult{}
	}

	var gen []*rule.Rule
	var imports []interface{}

	// Generate a lean_module for each .lean file
	for _, file := range leanFiles {
		// Compute workspace-relative path for module naming
		var wsRelPath string
		if args.Rel == "" {
			wsRelPath = file
		} else {
			wsRelPath = filepath.Join(args.Rel, file)
		}

		moduleName := cfg.moduleNameFromPath(wsRelPath)

		r := rule.NewRule("lean_module", moduleName)
		r.SetAttr("src", file)
		// deps will be populated by Resolve() in a later phase

		gen = append(gen, r)

		// Store empty imports for now - will be populated in Phase G2
		imports = append(imports, []string{})
	}

	return language.GenerateResult{
		Gen:     gen,
		Imports: imports,
	}
}

// findLeanFiles returns all .lean files in the directory that should be processed.
func findLeanFiles(dir string, regularFiles []string, cfg *leanConfig) []string {
	var leanFiles []string

	for _, f := range regularFiles {
		if !strings.HasSuffix(f, ".lean") {
			continue
		}

		// Check exclude patterns
		if cfg.shouldExclude(f) {
			continue
		}

		// Verify file exists and is readable
		path := filepath.Join(dir, f)
		if _, err := os.Stat(path); err != nil {
			continue
		}

		leanFiles = append(leanFiles, f)
	}

	// Sort for deterministic output
	sort.Strings(leanFiles)

	return leanFiles
}

// Loads implements language.Language.
// Returns the .bzl files and symbols that generated rules need to load.
func (*leanLang) Loads() []rule.LoadInfo {
	return []rule.LoadInfo{
		{
			Name:    "@rules_lean//lean:defs.bzl",
			Symbols: []string{"lean_module"},
		},
	}
}

// Fix implements language.Language.
// Repairs deprecated usage patterns in existing rules.
func (*leanLang) Fix(c *config.Config, f *rule.File) {
	// No fixes needed for now
}
