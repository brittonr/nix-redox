# Build a standalone /etc derivation from allGeneratedFiles.
#
# Produces a store path where each managed file appears at its relative
# path (e.g., $out/etc/profile, $out/etc/passwd). Used by:
#   1. toplevel: linked at $toplevel/etc/ for activation symlink farm
#   2. rootTree: same files are also baked in for the initial disk image
#
# This separation lets `snix system switch` update /etc/static without
# rebuilding the entire rootTree.

{ hostPkgs, lib, allGeneratedFiles }:

hostPkgs.runCommand "redox-etc" { } (
  ''
    mkdir -p $out
  ''
  + lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      path: file:
      let
        dir = builtins.dirOf path;
        storeFile =
          if (file ? source) && file.source != null then
            file.source
          else
            hostPkgs.writeText (builtins.replaceStrings [ "/" ] [ "-" ] path) file.text;
      in
      ''
        ${lib.optionalString (dir != "." && dir != "/") "mkdir -p $out/${dir}"}
        cp ${storeFile} $out/${path}
        chmod ${file.mode or "0644"} $out/${path}
      ''
    ) allGeneratedFiles
  )
)
