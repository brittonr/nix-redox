# Options documentation generator
#
# Walks the adios module tree and extracts option metadata
# (path, type, default, description) for each module.
#
# Produces:
#   optionsJSON     — JSON file with all option metadata
#   optionsMarkdown — Rendered Markdown reference

{ hostPkgs, lib }:

let
  adios = import ../../vendor/adios;

  rootModule = adios: {
    name = "redox-system";
    modules = adios.lib.importModules ../../redox-system/modules;
  };

  loadFn = adios (rootModule adios);
  tree = loadFn { options = { }; };

  # Modules to skip (internal / infrastructure)
  skipModules = [ "build" "pkgs" ];

  # Extract options from a single module, producing a list of
  # { path, type, default, description } entries.
  extractOptions =
    modulePath: options:
    lib.concatLists (
      lib.mapAttrsToList (
        name: opt:
        let
          optPath = "${modulePath}.${name}";
        in
        # Skip internal options (start with _)
        if lib.hasPrefix "_" name then
          [ ]
        # Nested struct options — recurse
        else if (opt ? type) && (opt.type.name or "" == "struct") && (opt ? default) && builtins.isAttrs opt.default then
          [
            {
              path = optPath;
              type = opt.type.name or "struct";
              default = builtins.toJSON opt.default;
              description = opt.description or "";
            }
          ]
        # Regular option with type
        else if opt ? type then
          [
            {
              path = optPath;
              type = opt.type.name or opt.type._name or "unknown";
              default =
                if opt ? default then
                  (
                    if builtins.isString opt.default then
                      opt.default
                    else if builtins.isBool opt.default then
                      (if opt.default then "true" else "false")
                    else if builtins.isInt opt.default then
                      toString opt.default
                    else if builtins.isList opt.default then
                      builtins.toJSON opt.default
                    else if builtins.isAttrs opt.default then
                      builtins.toJSON opt.default
                    else
                      "<computed>"
                  )
                else if opt ? defaultFunc then
                  "<computed>"
                else
                  "<required>";
              description = opt.description or "";
            }
          ]
        # Sub-options block (no type, has nested options)
        else if opt ? options then
          extractOptions optPath opt.options
        else
          [ ]
      ) options
    );

  # Collect all options across all visible modules
  allOptions = lib.concatLists (
    lib.mapAttrsToList (
      moduleName: _:
      if builtins.elem moduleName skipModules then
        [ ]
      else
        let
          mod = tree.modules.${moduleName};
        in
        extractOptions "/${moduleName}" (mod.options or { })
    ) tree.modules
  );

  # Sort by path for stable output
  sortedOptions = builtins.sort (a: b: a.path < b.path) allOptions;

  optionsJson = builtins.toJSON sortedOptions;

  # Build the JSON derivation
  optionsJSON = hostPkgs.writeText "redox-options.json" optionsJson;

  # Build the Markdown derivation
  optionsMarkdown =
    hostPkgs.runCommand "redox-options-markdown"
      {
        json = optionsJSON;
      }
      ''
        ${hostPkgs.python3}/bin/python3 -c '
        import json, sys

        with open(sys.argv[1]) as f:
            options = json.load(f)

        # Group by top-level module
        modules = {}
        for opt in options:
            parts = opt["path"].lstrip("/").split(".")
            mod = parts[0]
            modules.setdefault(mod, []).append(opt)

        lines = ["# Redox OS Module Options Reference", ""]
        lines.append("Auto-generated from adios module definitions.")
        lines.append("")

        for mod in sorted(modules.keys()):
            opts = modules[mod]
            lines.append(f"## /{mod}")
            lines.append("")
            lines.append("| Option | Type | Default | Description |")
            lines.append("|--------|------|---------|-------------|")
            for o in opts:
                name = o["path"]
                typ = o["type"]
                default = o["default"].replace("|", "\\|").replace("\n", " ")
                if len(default) > 60:
                    default = default[:57] + "..."
                desc = o["description"].replace("|", "\\|").replace("\n", " ")
                if len(desc) > 80:
                    desc = desc[:77] + "..."
                lines.append(f"| `{name}` | {typ} | {default} | {desc} |")
            lines.append("")

        with open(sys.argv[2], "w") as f:
            f.write("\n".join(lines) + "\n")
        ' "$json" "$out"
      '';
in
{
  inherit optionsJSON optionsMarkdown;
}
