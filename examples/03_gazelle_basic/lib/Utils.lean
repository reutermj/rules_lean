-- Utility functions for string manipulation
import Init.Data.String

def exclaim (s : String) : String :=
  s ++ "!"

def whisper (s : String) : String :=
  s.toLower
