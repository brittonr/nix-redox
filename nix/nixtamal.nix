# flake.nix without flakes: evaluates the flake with every flake.lock node
# fetched from the Nixtamal pin of the same name (nix/tamal) and wired together
# the way flake.lock wires them, as flake-compat does.
#
# Used by default.nix and shell.nix; see docs/nixtamal.md.
let
  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  pins = import ./tamal { };

  # A flake's own source is its Git-tracked files. `shallow` admits shallow
  # clones such as CI checkouts and does not change the files.
  rootSource =
    if builtins.pathExists ../.git then
      builtins.fetchGit {
        url = toString ../.;
        shallow = true;
      }
    else
      {
        outPath = builtins.path {
          path = ../.;
          name = "source";
        };
      };

  sourceInfo =
    key:
    if key == lock.root then
      rootSource
    else
      let
        pin =
          pins.${key} or (throw (
            "nix/tamal has no pin for flake.lock node `${key}`; add it to nix/tamal/manifest.kdl "
            + "and run `nixtamal lock ${key}` from the repository root"
          ));
      in
      if builtins.isAttrs pin then pin else { outPath = pin; };

  # flake.lock records an input as a node key or, for `follows`, as a path of
  # input names starting at the root node.
  resolve = spec: if builtins.isList spec then follow lock.root spec else spec;
  follow =
    key: path:
    if path == [ ] then
      key
    else
      follow (resolve lock.nodes.${key}.inputs.${builtins.head path}) (builtins.tail path);

  nodes = builtins.mapAttrs (
    key: node:
    let
      info = sourceInfo key;
      inputs = builtins.mapAttrs (_: spec: nodes.${resolve spec}) (node.inputs or { });
      outputs = (import "${info}/flake.nix").outputs (inputs // { self = flake; });
      flake =
        outputs
        // info
        // {
          inherit inputs outputs;
          sourceInfo = info;
          _type = "flake";
        };
    in
    if node.flake or true then flake else info
  ) lock.nodes;
in
nodes.${lock.root}
