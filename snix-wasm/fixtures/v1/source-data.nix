let
  text = "quotes: ' \"; shell: $(false)";
in
builtins.substring 0 6 text
