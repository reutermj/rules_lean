-- Application runner that uses lib modules
import lib.Greeter

def run : IO Unit := do
  IO.println (greet "Gazelle")
  IO.println (greetQuietly "Gazelle")
