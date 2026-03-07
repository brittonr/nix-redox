drvAttrs@{
  outputs ? [ "out" ],
  ...
}:
let
  strict = derivationStrict drvAttrs;
  commonAttrs =
    drvAttrs
    // (builtins.listToAttrs outputsList)
    // {
      all = map (x: x.value) outputsList;
      inherit drvAttrs;
    };
  outputToAttrListElement = outputName: {
    name = outputName;
    value = commonAttrs // {
      outPath = builtins.getAttr outputName strict;
      drvPath = strict.drvPath;
      type = "derivation";
      inherit outputName;
    };
  };
  outputsList = map outputToAttrListElement outputs;
in
(builtins.head outputsList).value
