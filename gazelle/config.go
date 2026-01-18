package lean

import (
	"flag"
	"path/filepath"
	"strings"

	"github.com/bazelbuild/bazel-gazelle/config"
	"github.com/bazelbuild/bazel-gazelle/rule"
)

// ExternalPackage represents an external Lean package from Lake.
type ExternalPackage struct {
	// Name is the package name (e.g., "Cli")
	Name string
	// ModuleRoot is the root module name exported by this package (e.g., "Cli")
	// Imports starting with this prefix map to this package.
	ModuleRoot string
	// Repo is the Bazel repository name (e.g., "lean_deps")
	Repo string
}

// leanConfig holds Lean-specific configuration for a directory.
type leanConfig struct {
	// moduleRoot is the prefix to strip from module names.
	// If set to "lib", then "lib/Foo/Bar.lean" becomes module "Foo.Bar".
	// If empty, workspace-relative paths are used as-is.
	moduleRoot string

	// excludePatterns are glob patterns for files to exclude from generation.
	excludePatterns []string

	// externalPackages maps module prefixes to external packages.
	// Used to resolve imports like "Cli" or "Cli.Basic" to @lean_deps//Cli:Cli.Basic
	externalPackages []ExternalPackage
}

// GetLeanConfig returns the Lean configuration for a given Gazelle config.
func GetLeanConfig(c *config.Config) *leanConfig {
	cfg, ok := c.Exts[languageName].(*leanConfig)
	if !ok {
		return &leanConfig{}
	}
	return cfg
}

// RegisterFlags implements config.Configurer.
func (*leanLang) RegisterFlags(fs *flag.FlagSet, cmd string, c *config.Config) {
	// Initialize extension config
	c.Exts[languageName] = &leanConfig{}
}

// CheckFlags implements config.Configurer.
func (*leanLang) CheckFlags(fs *flag.FlagSet, c *config.Config) error {
	return nil
}

// KnownDirectives implements config.Configurer.
// Returns the list of directives this extension recognizes in BUILD files.
func (*leanLang) KnownDirectives() []string {
	return []string{
		"lean_root",     // Set module root prefix to strip
		"lean_exclude",  // Exclude files matching pattern
		"lean_external", // Map external package: name=ModuleRoot@repo
	}
}

// Configure implements config.Configurer.
// Called for each directory with an optional BUILD file.
func (*leanLang) Configure(c *config.Config, rel string, f *rule.File) {
	// Get or create config for this directory
	var cfg *leanConfig
	if raw, ok := c.Exts[languageName]; ok {
		// Clone parent config
		parent := raw.(*leanConfig)
		cfg = &leanConfig{
			moduleRoot:       parent.moduleRoot,
			excludePatterns:  append([]string{}, parent.excludePatterns...),
			externalPackages: append([]ExternalPackage{}, parent.externalPackages...),
		}
	} else {
		cfg = &leanConfig{}
	}
	c.Exts[languageName] = cfg

	// Process directives from BUILD file
	if f == nil {
		return
	}

	for _, d := range f.Directives {
		switch d.Key {
		case "lean_root":
			// # gazelle:lean_root lib
			// Sets the module root - this prefix is stripped from module names
			cfg.moduleRoot = strings.TrimSpace(d.Value)

		case "lean_exclude":
			// # gazelle:lean_exclude test/**
			// Adds a pattern to exclude from generation
			pattern := strings.TrimSpace(d.Value)
			if pattern != "" {
				cfg.excludePatterns = append(cfg.excludePatterns, pattern)
			}

		case "lean_external":
			// # gazelle:lean_external Cli@lean_deps
			// Maps an external package module root to a Bazel repository.
			// Format: ModuleRoot@repo or ModuleRoot=PackageName@repo
			value := strings.TrimSpace(d.Value)
			if value == "" {
				continue
			}

			var pkg ExternalPackage

			// Parse format: ModuleRoot@repo or ModuleRoot=PackageName@repo
			if atIdx := strings.Index(value, "@"); atIdx != -1 {
				beforeAt := value[:atIdx]
				pkg.Repo = value[atIdx+1:]

				// Check for = in the part before @
				if eqIdx := strings.Index(beforeAt, "="); eqIdx != -1 {
					pkg.ModuleRoot = beforeAt[:eqIdx]
					pkg.Name = beforeAt[eqIdx+1:]
				} else {
					// ModuleRoot and Name are the same
					pkg.ModuleRoot = beforeAt
					pkg.Name = beforeAt
				}
			} else {
				// No @, use default repo "lean_deps"
				if eqIdx := strings.Index(value, "="); eqIdx != -1 {
					pkg.ModuleRoot = value[:eqIdx]
					pkg.Name = value[eqIdx+1:]
				} else {
					pkg.ModuleRoot = value
					pkg.Name = value
				}
				pkg.Repo = "lean_deps"
			}

			if pkg.ModuleRoot != "" && pkg.Name != "" && pkg.Repo != "" {
				cfg.externalPackages = append(cfg.externalPackages, pkg)
			}
		}
	}
}

// resolveExternalImport checks if an import matches an external package.
// Returns the Bazel label if found, or empty string if not an external import.
func (cfg *leanConfig) resolveExternalImport(moduleName string) string {
	for _, pkg := range cfg.externalPackages {
		// Check if import matches this package's module root
		if moduleName == pkg.ModuleRoot || strings.HasPrefix(moduleName, pkg.ModuleRoot+".") {
			// Map to @repo//:ModuleName (flat structure at root)
			// e.g., import Cli.Basic -> @lean_deps//:Cli.Basic
			return "@" + pkg.Repo + "//:" + moduleName
		}
	}
	return ""
}

// shouldExclude checks if a file path matches any exclude pattern.
func (cfg *leanConfig) shouldExclude(path string) bool {
	for _, pattern := range cfg.excludePatterns {
		if matched, _ := filepath.Match(pattern, path); matched {
			return true
		}
		// Also try matching just the filename
		if matched, _ := filepath.Match(pattern, filepath.Base(path)); matched {
			return true
		}
	}
	return false
}

// moduleNameFromPath converts a file path to a Lean module name.
// The pkgRel parameter is the package-relative directory (e.g., "lib" for //lib).
// This is stripped from the path to avoid redundant names like "lib:lib.Greeter".
// Example: "lib/Greeter.lean" with pkgRel="lib" -> "Greeter"
// Example: "lib/Foo/Bar.lean" with pkgRel="lib" -> "Foo.Bar"
// Example: "Greeter.lean" with pkgRel="" -> "Greeter"
func (cfg *leanConfig) moduleNameFromPath(path string, pkgRel string) string {
	// Remove .lean extension
	name := strings.TrimSuffix(path, ".lean")

	// Strip module root prefix if configured
	if cfg.moduleRoot != "" {
		prefix := cfg.moduleRoot + "/"
		name = strings.TrimPrefix(name, prefix)
	}

	// Strip the package-relative directory to avoid redundant names
	// e.g., for //lib package, "lib/Greeter" becomes "Greeter"
	if pkgRel != "" {
		prefix := pkgRel + "/"
		name = strings.TrimPrefix(name, prefix)
	}

	// Convert path separators to dots
	name = strings.ReplaceAll(name, "/", ".")

	return name
}
