-- A simple string utilities module

namespace Utils.String

def greet (name : String) : String := s!"Hello, {name}!"

def shout (s : String) : String := s.toUpper ++ "!!"

end Utils.String
