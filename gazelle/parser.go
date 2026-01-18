package lean

import (
	"bufio"
	"os"
	"regexp"
	"strings"
)

// ImportInfo represents a single import statement from a Lean file.
type ImportInfo struct {
	Module     string // The module name (e.g., "Init.Data.String")
	IsPrivate  bool   // true if "private import"
	IsAll      bool   // true if "import all"
	IsMeta     bool   // true if "meta import"
}

// importRegex matches Lean import statements.
// Supports: import, private import, import all, meta import
var importRegex = regexp.MustCompile(`^\s*(private\s+)?(meta\s+)?import\s+(all\s+)?(\S+)`)

// ParseImports extracts import statements from a Lean source file.
// Returns the list of imports found, or an error if the file can't be read.
func ParseImports(path string) ([]ImportInfo, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var imports []ImportInfo
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := scanner.Text()

		// Skip comments and empty lines
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "--") || strings.HasPrefix(trimmed, "/-") {
			continue
		}

		// Check if this is an import statement
		matches := importRegex.FindStringSubmatch(line)
		if matches == nil {
			// Once we see a non-import line (after imports), we can stop
			// Lean requires imports at the top of the file
			if !strings.HasPrefix(trimmed, "import") && len(imports) > 0 {
				break
			}
			continue
		}

		imp := ImportInfo{
			IsPrivate: matches[1] != "",
			IsMeta:    matches[2] != "",
			IsAll:     matches[3] != "",
			Module:    matches[4],
		}

		imports = append(imports, imp)
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return imports, nil
}

// ParseImportsFromDir parses imports from multiple Lean files in a directory.
// Returns a map from filename to imports.
func ParseImportsFromDir(dir string, files []string) (map[string][]ImportInfo, error) {
	result := make(map[string][]ImportInfo)

	for _, f := range files {
		path := dir + "/" + f
		imports, err := ParseImports(path)
		if err != nil {
			// Log error but continue - file might not exist or be readable
			continue
		}
		result[f] = imports
	}

	return result, nil
}
