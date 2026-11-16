let
  value = {
    answer = 6 * 7;
    nested = {
      enabled = true;
    };
  };
in
builtins.deepSeq value value
