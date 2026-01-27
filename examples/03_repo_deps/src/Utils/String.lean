-- Utils/String.lean
-- A utility module with string functions (no dependencies)

def greet (name : String) : String := s!"Hello, {name}!"

def shout (msg : String) : String := msg.toUpper ++ "!"
