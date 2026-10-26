# Evaluated by Snix inside Redox; uses the host package's pinned lock/vendor.
derivation {
  name = "redox-initfs-tools-native";
  system = "x86_64-unknown-redox";
  builder = "/nix/system/profile/bin/bash";
  source = ./initfs-tools;
  bootstrapInputs = builtins.readFile ./seed.json;
  args = [ "--noprofile" "--norc" "-c" ''
    set -eu
    export PATH=/nix/system/profile/bin:/bin:/usr/bin
    export LD_LIBRARY_PATH=/nix/system/profile/lib:/usr/lib/rustc:/lib
    export HOME="$TMPDIR/home"
    export CARGO_HOME="$TMPDIR/cargo-home"
    export CARGO_TARGET_DIR="$TMPDIR/target"
    export CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1
    export RUSTC=/nix/system/profile/bin/rustc
    export AR=/nix/system/profile/bin/llvm-ar
    export CC=/nix/system/profile/bin/cc
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
