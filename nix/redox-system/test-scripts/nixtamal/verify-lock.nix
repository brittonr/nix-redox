# Evaluate the actual generated loader, not a test replacement for it.
{ value }:
let
  directory = /tmp/nixtamal-test/tamal;
  inputs = import directory { bootstrap-pkgs = { }; };
in
assert builtins.attrNames inputs == [ "archive" "git" ];
assert import inputs.archive == value;
assert import inputs.git == "nixtamal-git-pinned";
true
