# Evaluated by Snix inside Redox; uses the host package's pinned lock/vendor.
let
  tools = import ./stage0-tools.nix;
in
derivation {
  name = "redox-initfs-tools-native";
  system = "x86_64-unknown-redox";
  builder = "${tools.bash}/bin/bash";
  source = ./initfs-tools;
  bootstrapInputs = builtins.readFile ./seed.json;
  args = [ "--noprofile" "--norc" "-c" ''
    set -eu
    export PATH=${tools.rustc}/bin:${tools.llvm}/bin:${tools.uutils}/bin:${tools.bash}/bin:/bin:/usr/bin
    export LD_LIBRARY_PATH=${tools.rustc}/lib:${tools.llvm}/lib:/usr/lib/rustc:/lib
    export HOME="$TMPDIR/home"
    export CARGO_HOME="$TMPDIR/cargo-home"
    export CARGO_TARGET_DIR="$TMPDIR/target"
    export CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1
    export RUSTC=${tools.rustc}/bin/rustc
    export AR=${tools.llvm}/bin/llvm-ar
    export CC=${tools.llvm}/bin/clang
    mkdir -p "$HOME" "$CARGO_HOME" "$out/bin"
    cp -r "$source" "$TMPDIR/source"
    chmod -R u+w "$TMPDIR/source"
    cat > "$CARGO_HOME/config.toml" <<EOF
    [source.crates-io]
    replace-with = "vendored-sources"
    [source.vendored-sources]
    directory = "$source/vendor"
    [net]
    offline = true
    EOF
    cd "$TMPDIR/source"
    cargo build --manifest-path initfs/tools/Cargo.toml --offline --frozen \
      --target x86_64-unknown-redox --release --bins
    cp "$CARGO_TARGET_DIR/x86_64-unknown-redox/release/redox-initfs-ar" "$out/bin/"
    cp "$CARGO_TARGET_DIR/x86_64-unknown-redox/release/redox-initfs-dump" "$out/bin/"
  '' ];
}
