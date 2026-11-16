let
  math = import ./lib/math.nix;
in
math.square 7 + math.offset
