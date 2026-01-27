-- Core/Logic.lean
-- Core logic module (depends on Utils.Math and Utils.String)

import Utils.Math
import Utils.String

def describe (n : Nat) : String :=
  let doubled := Utils.Math.double n
  Utils.String.greet s!"number {doubled}"

def exclaim (n : Nat) : String :=
  Utils.String.shout s!"The answer is {n}"
