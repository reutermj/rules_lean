-- Test that module name is derived from workspace-relative path.
-- This file is at subdir/inner/Nested.lean, so module name should be "subdir.inner.Nested".

def main : IO Unit := do
  IO.println "Nested module works!"
  IO.println s!"I am module: subdir.inner.Nested"
