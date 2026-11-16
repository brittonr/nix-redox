# Real Nix store graph and exporter checks; no executable stand-ins.
{ pkgs, lib }:
let
  mkCache = import ../lib/mk-binary-cache.nix {
    hostPkgs = pkgs;
    inherit lib;
  };
  c = pkgs.writeText "cache-closure-c" "closure leaf\n";
  b = pkgs.writeText "cache-closure-b" "${c}\n";
  a = pkgs.writeText "cache-closure-a" "${b}\n";
  left = pkgs.writeText "cache-closure-left" "${c}\n";
  right = pkgs.writeText "cache-closure-right" "${c}\n";
  diamond = pkgs.writeText "cache-closure-diamond" "${left}\n${right}\n";
  self = pkgs.runCommand "cache-closure-self" { } ''
    printf '%s\n' "$out" > "$out"
  '';
  cache = mkCache {
    packages = {
      chain = a;
      inherit diamond self;
    };
  };
in
{
  inherit cache;
  contracts =
    pkgs.runCommand "binary-cache-contract-tests" { nativeBuildInputs = [ pkgs.python3 ]; }
      ''
        CACHE_BUILDER=${../lib/build-binary-cache.py} python3 ${../lib/test-build-binary-cache.py}
        touch "$out"
      '';
  closure =
    pkgs.runCommand "binary-cache-real-closure-test"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.zstd
        ];
      }
      ''
        python3 - ${cache} <<'PY'
        import hashlib, json, pathlib, subprocess, sys
        root = pathlib.Path(sys.argv[1])
        closure = json.loads((root / "closure.json").read_text())
        index = json.loads((root / "packages.json").read_text())
        paths = closure["paths"]
        assert closure["version"] == 1
        assert index["version"] == 2
        assert index["installationMode"] == "recursive"
        assert set(index["packages"]) == {"chain", "diamond", "self"}
        assert paths["${a}"]["references"] == ["${b}"]
        assert paths["${b}"]["references"] == ["${c}"]
        assert paths["${c}"]["references"] == []
        assert paths["${diamond}"]["references"] == sorted(["${left}", "${right}"])
        assert paths["${left}"]["references"] == ["${c}"]
        assert paths["${right}"]["references"] == ["${c}"]
        assert paths["${self}"]["references"] == ["${self}"]
        assert set(paths) == {"${a}", "${b}", "${c}", "${left}", "${right}", "${diamond}", "${self}"}
        for path, member in paths.items():
            narinfo = (root / (pathlib.Path(path).name[:32] + ".narinfo")).read_text()
            fields = dict(line.split(": ", 1) for line in narinfo.splitlines())
            assert fields["StorePath"] == path
            assert fields["References"].split() == [pathlib.Path(ref).name for ref in member["references"]]
            archive = subprocess.check_output(["zstd", "-d", "-c", str(root / member["url"])])
            assert "sha256:" + hashlib.sha256(archive).hexdigest() == member["narHash"]
            assert len(archive) == member["narSize"]
        transport = json.loads((root / "transport.json").read_text())
        assert transport["version"] == 1
        assert set(transport["packages"]) == set(index["packages"])
        for name, package in transport["packages"].items():
            assert package["storePath"] == index["packages"][name]["storePath"]
            reached, pending = set(), [package["storePath"]]
            while pending:
                path = pending.pop()
                if path not in reached:
                    reached.add(path)
                    pending.extend(paths[path]["references"])
            expected = {"packages.json", "closure.json", "nix-cache-info"}
            for path in reached:
                expected.add(pathlib.Path(path).name[:32] + ".narinfo")
                expected.add(paths[path]["url"])
            assert [entry["path"] for entry in package["files"]] == sorted(expected)
            for entry in package["files"]:
                content = (root / entry["path"]).read_bytes()
                assert hashlib.sha256(content).hexdigest() == entry["sha256"]
                assert len(content) == entry["size"]
        PY
        touch "$out"
      '';
}
