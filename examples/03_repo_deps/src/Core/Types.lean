-- Core/Types.lean
-- Core types module (depends on Utils.Math)

import Utils.Math

structure Point where
  x : Nat
  y : Nat

def Point.distanceSquared (p1 p2 : Point) : Nat :=
  let dx := if p1.x > p2.x then p1.x - p2.x else p2.x - p1.x
  let dy := if p1.y > p2.y then p1.y - p2.y else p2.y - p1.y
  Utils.Math.add (Utils.Math.square dx) (Utils.Math.square dy)
