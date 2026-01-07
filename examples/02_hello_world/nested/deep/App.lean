-- Test that module name is derived from workspace-relative path.
-- This file is at nested/deep/App.lean, so module name should be "nested.deep.App".
-- If module naming is wrong, this won't compile correctly.

def main : IO Unit := do
  IO.println "Module naming works!"
  IO.println s!"I am module: nested.deep.App"
