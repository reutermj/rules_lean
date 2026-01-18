-- A simple greeter module
import lib.Utils

def greet (name : String) : String :=
  exclaim s!"Hello, {name}"

def greetQuietly (name : String) : String :=
  whisper s!"hello, {name}"
