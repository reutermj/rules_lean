-- Main entry point
import lib.Greeter

def main : IO Unit :=
  IO.println (greet "World")
