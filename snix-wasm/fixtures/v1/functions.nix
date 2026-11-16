let
  twice = f: x: f (f x);
in
twice (x: x + 3) 4
