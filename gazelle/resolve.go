package lean

import (
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/label"
	"github.com/bazelbuild/bazel-gazelle/repo"
	"github.com/bazelbuild/bazel-gazelle/resolve"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// Imports implements resolve.Resolver.
// Returns import specifications for indexing this rule.
// Other rules can find this rule by looking up these imports.
func (*leanLang) Imports(c *config.Config, r *rule.Rule, f *rule.File) []resolve.ImportSpec {
	if r.Kind() != "lean_module" {
		return nil
	}

	// Compute the full Lean module name from package path + rule name
	// e.g., for //lib:Greeter, the full module name is "lib.Greeter"
	// This is what Lean uses in import statements
	ruleName := r.Name()
	var moduleName string
	if f != nil && f.Pkg != "" {
		// Convert package path to module prefix (e.g., "lib" -> "lib.")
		pkgPrefix := strings.ReplaceAll(f.Pkg, "/", ".")
		moduleName = pkgPrefix + "." + ruleName
	} else {
		moduleName = ruleName
	}

	return []resolve.ImportSpec{
		{
			Lang: languageName,
			Imp:  moduleName,
		},
	}
}

// Embeds implements resolve.Resolver.
// Returns labels of rules that this rule embeds.
// Lean modules don't embed other rules.
func (*leanLang) Embeds(r *rule.Rule, from label.Label) []label.Label {
	return nil
}

// Resolve implements resolve.Resolver.
// Translates import strings into Bazel labels for the deps attribute.
func (l *leanLang) Resolve(
	c *config.Config,
	ix *resolve.RuleIndex,
	rc *repo.RemoteCache,
	r *rule.Rule,
	imports interface{},
	from label.Label,
) {
	if r.Kind() != "lean_module" {
		return
	}

	// In Phase G1, imports is always an empty slice.
	// In Phase G2, we'll populate this with actual imports from the source file.
	impList, ok := imports.([]string)
	if !ok || len(impList) == 0 {
		return
	}

	var deps []string
	for _, imp := range impList {
		// Skip stdlib imports (Init, Lean, Std, Lake)
		if isStdlibImport(imp) {
			continue
		}

		// Look up the import in the rule index
		res := ix.FindRulesByImport(
			resolve.ImportSpec{Lang: languageName, Imp: imp},
			languageName,
		)

		if len(res) > 0 {
			// Found a matching rule
			depLabel := res[0].Label
			// Convert to string, using appropriate format based on location
			if depLabel.Repo == from.Repo {
				if depLabel.Pkg == from.Pkg {
					// Same package: use relative label
					deps = append(deps, ":"+depLabel.Name)
				} else {
					// Same repo, different package: use //pkg:target
					deps = append(deps, "//"+depLabel.Pkg+":"+depLabel.Name)
				}
			} else {
				// Different repo: use full label
				deps = append(deps, depLabel.String())
			}
		}
		// If not found, skip - will result in build error that user can fix
	}

	if len(deps) > 0 {
		r.SetAttr("deps", deps)
	}
}

// isStdlibImport checks if an import is from the Lean standard library.
// These don't need explicit deps - they're provided by the toolchain.
func isStdlibImport(imp string) bool {
	stdlibPrefixes := []string{
		"Init",
		"Lean",
		"Std",
		"Lake",
	}

	for _, prefix := range stdlibPrefixes {
		if imp == prefix {
			return true
		}
		if len(imp) > len(prefix) && imp[:len(prefix)+1] == prefix+"." {
			return true
		}
	}
	return false
}
