-- Main.lean
-- Main entry point (depends on Core.Types and Core.Logic)

import Core.Types
import Core.Logic

def main : IO Unit := do
  let p1 : Core.Types.Point := { x := 0, y := 0 }
  let p2 : Core.Types.Point := { x := 3, y := 4 }
  let dist := Core.Types.Point.distanceSquared p1 p2
  IO.println (Core.Logic.describe dist)
  IO.println (Core.Logic.exclaim dist)
