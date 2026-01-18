-- Example using the external Cli library
import Cli

open Cli

def runGreetCmd (p : Parsed) : IO UInt32 := do
  let name := p.positionalArg! "name" |>.as! String
  let greeting := if p.hasFlag "excited" then "Hello, " ++ name ++ "!" else "Hello, " ++ name
  IO.println greeting
  return 0

def greetCmd : Cmd := `[Cli|
  greet VIA runGreetCmd;
  "Greet someone by name."

  FLAGS:
    e, excited; "Add excitement to the greeting"

  ARGS:
    name : String; "The name to greet"
]

def main (args : List String) : IO UInt32 :=
  greetCmd.validate args
