-- Test file to demonstrate error path reporting issue
def main : IO Unit := do
  -- This line should produce a type error
  let x : String := 42
  IO.println "This won't compile"
