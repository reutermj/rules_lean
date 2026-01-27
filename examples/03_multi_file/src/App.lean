-- Main application module that imports utilities
import Utils.Math
import Utils.String

def main : IO Unit := do
  let n := 5
  IO.println s!"double({n}) = {Utils.Math.double n}"
  IO.println s!"square({n}) = {Utils.Math.square n}"
  IO.println (Utils.String.greet "Lean")
  IO.println (Utils.String.shout "bazel works!")
