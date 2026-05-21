# snix-upstream-source — Extract upstream snix crates and apply Redox patches
#
# Fetches the snix monorepo at a pinned commit, extracts the crate
# subdirectories we need, and applies the Redox systems patch to
# snix-eval. The output is a directory tree that snix-redox references
# as workspace members (under `upstream/`).
#
# Extracted crates:
#   nix-compat, nix-compat-derive, eval, eval/builtin-macros,
#   glue, store, castore, build, serde, tracing, cli/base
#
# Patches applied:
#   eval/src/systems.rs — add "redox" to is_second_coordinate()
#   glue/src/builder/mod.rs — make derivation_into_build_request public
#   glue/src/lib.rs — make fetchurl module public
#   glue/src/fetchurl.rs — make fetchurl_derivation_to_fetch and Error public
#
# Upstream pin: 34604636d7 (2026-03-26) — canon branch

{ pkgs }:

let
  snixSrc = pkgs.fetchgit {
    url = "https://git.snix.dev/snix/snix.git";
    rev = "34604636d7e3adbad6f7f909c98bb493f26855f9";
    hash = "sha256-of/rQYKmysPEqO2Snx199VcZjey+5YxJZD3QgLQanN4=";
  };

  crates = [
    "nix-compat"
    "nix-compat-derive"
    "eval"
    "glue"
    "store"
    "castore"
    "build"
    "serde"
    "tracing"
    "cli/base"
  ];

in
pkgs.runCommand "snix-upstream-source" { } ''
  mkdir -p $out/cli

  ${builtins.concatStringsSep "\n" (map (crate: ''
    cp -r ${snixSrc}/snix/${crate} $out/${crate}
  '') crates)}

  # Make crates writable for Cargo.toml/source patching
  chmod -R u+w $out/build $out/store $out/castore $out/nix-compat $out/tracing $out/cli

  # Remove fuse feature requirement from snix-build → snix-castore dep.
  # Upstream snix-build unconditionally enables snix-castore/fuse, which
  # pulls in fuse-backend-rs → vm-memory (Linux-only). Since we use
  # DummyBuildService, we don't need FUSE.
  sed -i 's|snix-castore = { path = "../castore", features = \["fuse"\] }|snix-castore = { path = "../castore" }|' $out/build/Cargo.toml

  # Gate the bwrap/oci modules that use snix_castore::fs behind a
  # cargo feature so they don't compile when fs is not enabled.
  # The modules are already cfg(target_os = "linux"), but they still
  # compile on a linux host and need castore::fs.
  # Change: #[cfg(target_os = "linux")] → #[cfg(all(target_os = "linux", feature = "linux-sandbox"))]
  sed -i 's|#\[cfg(target_os = "linux")\]|#[cfg(all(target_os = "linux", feature = "linux-sandbox"))]|g' $out/build/src/lib.rs $out/build/src/buildservice/mod.rs

  # Also gate imports of bwrap/oci in from_addr.rs
  chmod u+w $out/build/src/buildservice/from_addr.rs
  sed -i 's|use crate::buildservice::bwrap|#[cfg(feature = "linux-sandbox")] use crate::buildservice::bwrap|' $out/build/src/buildservice/from_addr.rs
  sed -i 's|use super::oci|#[cfg(feature = "linux-sandbox")] use super::oci|' $out/build/src/buildservice/from_addr.rs
  # Gate the match arms that use bwrap/oci
  sed -i '/"oci" =>/{s/^/        #[cfg(feature = "linux-sandbox")]\n/}' $out/build/src/buildservice/from_addr.rs
  sed -i '/"bwrap" =>/{s/^/        #[cfg(feature = "linux-sandbox")]\n/}' $out/build/src/buildservice/from_addr.rs

  # Disable cloud in snix-castore defaults (pulls bigtable_rs → tonic 0.14 → aws-lc).
  # Also disable tonic-reflection (unused on Redox).
  sed -i 's|default = \["cloud"\]|default = []|' $out/castore/Cargo.toml

  # Disable default features in snix-store (pulls cloud/bigtable, fuse, tonic-reflection).
  # Upstream dropped otlp from defaults between eee4779 and 2207a07; the new
  # default set is ["cloud", "fuse", "tonic-reflection"].
  sed -i 's|default = \["cloud", "fuse", "tonic-reflection"\]|default = []|' $out/store/Cargo.toml

  # Upstream still declares mimalloc as a normal dependency in snix-build,
  # snix-store, and nix-compat, but the production code paths do not use it.
  # Keep mimalloc only in dev/bench contexts so Redox cargo builds do not pull
  # libmimalloc-sys into the self-hosted workspace.
  SNIX_UPSTREAM_OUT="$out" ${pkgs.python3}/bin/python3 - <<'PY'
import os
from pathlib import Path

out = Path(os.environ["SNIX_UPSTREAM_OUT"])
replacements = {
    out / "build/Cargo.toml": (
        "tracing.workspace = true\nurl.workspace = true\nmimalloc.workspace = true\ntonic-reflection = { workspace = true, optional = true }\n",
        "tracing.workspace = true\nurl.workspace = true\ntonic-reflection = { workspace = true, optional = true }\n",
    ),
    out / "store/Cargo.toml": (
        "redb = { workspace = true, features = [\"logging\"] }\nmimalloc.workspace = true\ntonic-reflection = { workspace = true, optional = true }\n",
        "redb = { workspace = true, features = [\"logging\"] }\ntonic-reflection = { workspace = true, optional = true }\n",
    ),
    out / "nix-compat/Cargo.toml": (
        "hashbrown = { workspace = true, optional = true }\nmimalloc.workspace = true\nnom.workspace = true\n",
        "hashbrown = { workspace = true, optional = true }\nnom.workspace = true\n",
    ),
}

for path, (old, new) in replacements.items():
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"expected snippet not found in {path}")
    path.write_text(text.replace(old, new, 1))
PY

  # Avoid tokio-macros on Redox. The Redox self-hosting rustc currently spins
  # while compiling tokio-macros, and the production snix binary does not need
  # Tokio proc-macro attributes. Keep the macros feature for non-Redox targets
  # so upstream #[tokio::test] host validation continues to compile.
  SNIX_UPSTREAM_OUT="$out" ${pkgs.python3}/bin/python3 - <<'PY'
import os
from pathlib import Path

out = Path(os.environ["SNIX_UPSTREAM_OUT"])
replacements = {
    out / "castore/Cargo.toml": (
        'tokio = { workspace = true, features = [\n  "fs",\n  "macros",\n  "net",\n  "rt",\n  "rt-multi-thread",\n  "signal",\n] }\n',
        'tokio = { workspace = true, features = [\n  "fs",\n  "net",\n  "rt",\n  "rt-multi-thread",\n  "signal",\n] }\n',
        '\n[target.\'cfg(not(target_os = "redox"))\'.dependencies]\ntokio = { workspace = true, features = ["macros"] }\n',
    ),
    out / "store/Cargo.toml": (
        'tokio = { workspace = true, features = [\n  "fs",\n  "macros",\n  "net",\n  "rt",\n  "rt-multi-thread",\n] }\n',
        'tokio = { workspace = true, features = [\n  "fs",\n  "net",\n  "rt",\n  "rt-multi-thread",\n] }\n',
        '\n[target.\'cfg(not(target_os = "redox"))\'.dependencies]\ntokio = { workspace = true, features = ["macros"] }\n',
    ),
    out / "tracing/Cargo.toml": (
        'tokio = { workspace = true, features = ["macros", "signal", "sync", "rt"] }\n',
        'tokio = { workspace = true, features = ["signal", "sync", "rt"] }\n',
        '\n[target.\'cfg(not(target_os = "redox"))\'.dependencies]\ntokio = { workspace = true, features = ["macros"] }\n',
    ),
    out / "nix-compat/Cargo.toml": (
        'tokio = { workspace = true, features = [\n  "io-util",\n  "macros",\n  "sync",\n], optional = true }\n',
        'tokio = { workspace = true, features = [\n  "io-util",\n  "sync",\n], optional = true }\n',
        '\n[target.\'cfg(not(target_os = "redox"))\'.dependencies]\ntokio = { workspace = true, features = ["macros"], optional = true }\n',
    ),
}

for path, (old, new, target_dep) in replacements.items():
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"expected tokio feature snippet not found in {path}")
    text = text.replace(old, new, 1)
    marker = "\n[build-dependencies]\n" if "\n[build-dependencies]\n" in text else "\n[dev-dependencies]\n"
    if target_dep.strip() not in text:
        text = text.replace(marker, target_dep + marker, 1)
    path.write_text(text)

# object_store unconditionally depends on tokio/macros. The Redox self-hosted
# snix build only uses local/redb/grpc services, so compile object_store-backed
# services only on non-Redox targets.
castore_toml = out / "castore/Cargo.toml"
text = castore_toml.read_text()
old = 'libc = { workspace = true, optional = true }\nobject_store = { workspace = true, features = ["http"] }\nparking_lot.workspace = true\n'
new = 'libc = { workspace = true, optional = true }\nparking_lot.workspace = true\n'
if old not in text:
    raise SystemExit("expected castore object_store dependency snippet not found")
text = text.replace(old, new, 1)
old = '[target.\'cfg(not(target_os = "redox"))\'.dependencies]\ntokio = { workspace = true, features = ["macros"] }\n'
new = '[target.\'cfg(not(target_os = "redox"))\'.dependencies]\nobject_store = { workspace = true, features = ["http"] }\ntokio = { workspace = true, features = ["macros"] }\n'
if old not in text:
    raise SystemExit("expected castore non-Redox target dependency section not found")
castore_toml.write_text(text.replace(old, new, 1))

source_replacements = {
    out / "cli/base/src/lib.rs": [
        ("""    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
""", """    #[cfg(target_os = "redox")]
    {
        // Redox self-hosting avoids Tokio's proc-macro crate because rustc
        // currently spins compiling tokio-macros. Redox does not need the
        // SIGTERM branch here, so avoid tokio::select! on that target.
        ctrl_c.await;
    }

    #[cfg(not(target_os = "redox"))]
    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
"""),
    ],
    out / "store/src/nar/import.rs": [
        ("""use tokio::{
    io::{AsyncBufRead, AsyncRead},
    sync::mpsc,
    try_join,
};
""", """use tokio::{
    io::{AsyncBufRead, AsyncRead},
    sync::mpsc,
};
"""),
        ("""    let (_, node) = try_join!(produce, consume)?;
""", """    // Avoid tokio::try_join! on Redox self-hosting because it requires
    // Tokio's proc-macro feature, which pulls in tokio-macros. Avoid
    // futures::try_join! too: futures-macro is also too expensive for the
    // current Redox self-hosting rustc.
    let (_, node) = futures::future::try_join(produce, consume).await?;
"""),
    ],
    out / "castore/src/blobservice/combinator.rs": [
        ("""        let (local, remote) =
            futures::join!(context.resolve(&self.near), context.resolve(&self.far));
""", """        let (local, remote) = futures::future::join(
            context.resolve(&self.near),
            context.resolve(&self.far),
        )
        .await;
"""),
    ],
    out / "castore/src/directoryservice/combinators.rs": [
        ("""        let (near, far) = futures::join!(
            context.resolve::<Self::Output>(&self.near),
            context.resolve::<Self::Output>(&self.far)
        );
""", """        let (near, far) = futures::future::join(
            context.resolve::<Self::Output>(&self.near),
            context.resolve::<Self::Output>(&self.far),
        )
        .await;
"""),
    ],
    out / "store/src/pathinfoservice/cache.rs": [
        ("""        let (near, far) = futures::join!(
            context.resolve::<Self::Output>(&self.near),
            context.resolve::<Self::Output>(&self.far)
        );
""", """        let (near, far) = futures::future::join(
            context.resolve::<Self::Output>(&self.near),
            context.resolve::<Self::Output>(&self.far),
        )
        .await;
"""),
    ],
    out / "store/src/pathinfoservice/nix_http.rs": [
        ("""        let (blob_service, directory_service) = futures::join!(
            context.resolve::<dyn BlobService>(&self.params.blob_service),
            context.resolve::<dyn DirectoryService>(&self.params.directory_service)
        );
""", """        let (blob_service, directory_service) = futures::future::join(
            context.resolve::<dyn BlobService>(&self.params.blob_service),
            context.resolve::<dyn DirectoryService>(&self.params.directory_service),
        )
        .await;
"""),
    ],
    out / "castore/src/blobservice/mod.rs": [
        ('mod memory;\nmod object_store;\n', 'mod memory;\n#[cfg(not(target_os = "redox"))]\nmod object_store;\n'),
        ('pub use self::memory::{MemoryBlobService, MemoryBlobServiceConfig};\npub use self::object_store::{ObjectStoreBlobService, ObjectStoreBlobServiceConfig};\n', 'pub use self::memory::{MemoryBlobService, MemoryBlobServiceConfig};\n#[cfg(not(target_os = "redox"))]\npub use self::object_store::{ObjectStoreBlobService, ObjectStoreBlobServiceConfig};\n'),
        ('pub(crate) fn register_blob_services(reg: &mut Registry) {\n    reg.register::<Box<dyn ServiceBuilder<Output = dyn BlobService>>, super::blobservice::ObjectStoreBlobServiceConfig>("objectstore");\n', 'pub(crate) fn register_blob_services(reg: &mut Registry) {\n    #[cfg(not(target_os = "redox"))]\n    reg.register::<Box<dyn ServiceBuilder<Output = dyn BlobService>>, super::blobservice::ObjectStoreBlobServiceConfig>("objectstore");\n'),
    ],
    out / "castore/src/directoryservice/mod.rs": [
        ('mod grpc;\nmod object_store;\n', 'mod grpc;\n#[cfg(not(target_os = "redox"))]\nmod object_store;\n'),
        ('pub use self::grpc::{GRPCDirectoryService, GRPCDirectoryServiceConfig};\npub use self::object_store::{ObjectStoreDirectoryService, ObjectStoreDirectoryServiceConfig};\n', 'pub use self::grpc::{GRPCDirectoryService, GRPCDirectoryServiceConfig};\n#[cfg(not(target_os = "redox"))]\npub use self::object_store::{ObjectStoreDirectoryService, ObjectStoreDirectoryServiceConfig};\n'),
        ('    reg.register::<Box<dyn ServiceBuilder<Output = dyn DirectoryService>>, super::directoryservice::ObjectStoreDirectoryServiceConfig>("objectstore");\n', '    #[cfg(not(target_os = "redox"))]\n    reg.register::<Box<dyn ServiceBuilder<Output = dyn DirectoryService>>, super::directoryservice::ObjectStoreDirectoryServiceConfig>("objectstore");\n'),
    ],
}
for path, reps in source_replacements.items():
    text = path.read_text()
    for old, new in reps:
        if old not in text:
            raise SystemExit(f"expected source snippet not found in {path}: {old!r}")
        text = text.replace(old, new, 1)
    path.write_text(text)
PY

  # NOTE: tonic tls-aws-lc → tls-ring override.
  # As of 2207a07, store/Cargo.toml uses `tonic.workspace = true` (no inline
  # features). The tls backend is controlled by the workspace [dependencies]
  # in snix-redox/Cargo.toml, where we set tls-ring. No sed needed here.

  # Make eval writable for patching
  chmod -R u+w $out/eval

  # Apply Redox systems patch: add "redox" to is_second_coordinate()
  patch -d $out/eval -p1 <<'PATCH'
--- a/src/systems.rs
+++ b/src/systems.rs
@@ -1,7 +1,7 @@
 /// true iff the argument is recognized by cppnix as the second
 /// coordinate of a "nix double"
 fn is_second_coordinate(x: &str) -> bool {
-    matches!(x, "linux" | "darwin" | "netbsd" | "openbsd" | "freebsd")
+    matches!(x, "linux" | "darwin" | "netbsd" | "openbsd" | "freebsd" | "redox")
 }

 /// This function takes an llvm triple (which may have three or four
PATCH

  # Make derivation_into_build_request public so snix-redox can use it.
  # Upstream keeps it pub(crate) because only snix-glue's own build
  # orchestration calls it. We need it in local_build.rs to convert
  # Derivation → BuildRequest for env var setup, refscan needles, etc.
  chmod -R u+w $out/glue
  sed -i 's|pub(crate) fn derivation_into_build_request|pub fn derivation_into_build_request|' $out/glue/src/builder/mod.rs

  # Make fetchurl module public so snix-redox can use fetchurl_derivation_to_fetch.
  sed -i 's|^mod fetchurl;|pub mod fetchurl;|' $out/glue/src/lib.rs
  sed -i 's|pub(crate) fn fetchurl_derivation_to_fetch|pub fn fetchurl_derivation_to_fetch|' $out/glue/src/fetchurl.rs
  sed -i 's|pub(crate) enum Error|pub enum Error|' $out/glue/src/fetchurl.rs

  # snix-glue only needs eval's impure runtime support.  Avoid eval's default
  # arbitrary/nix_tests features in the self-hosted snix binary closure; they
  # pull proptest/test-strategy/structmeta proc macros that Redox rustc spins on.
  sed -i 's|snix-eval = { path = "../eval" }|snix-eval = { path = "../eval", default-features = false, features = ["impure"] }|' $out/glue/Cargo.toml

  # Match the packaged snix build: avoid aborting when reqwest tries to load
  # native CA roots on Redox, where no system CA store exists.
  ${pkgs.python3}/bin/python3 ${../userspace/patches/patch-snix-fetcher-no-tls-panic.py} \
    $out/glue/src/fetchers/mod.rs

  chmod -R a-w $out/glue

  # Create proto path resolution structure.
  # The build.rs files reference protos as "snix/{crate}/protos/..." and
  # look for PROTO_ROOT env var (or default to "../..").
  # Create a snix/ directory with symlinks so the proto paths resolve
  # when PROTO_ROOT points here.
  mkdir -p $out/snix
  for crate in castore store build; do
    ln -s ../$crate $out/snix/$crate
  done

  # Pre-generate descriptor sets so Redox self-hosting builds do not need a
  # native protoc binary. The patched build.rs files load these .bin files and
  # fall back to compile_protos only when a descriptor file is absent.
  ${pkgs.protobuf}/bin/protoc \
    --include_imports \
    --include_source_info \
    -I $out \
    -I ${pkgs.protobuf}/include \
    -o $out/castore/protos/snix.castore.v1.bin \
    snix/castore/protos/castore.proto \
    snix/castore/protos/rpc_blobstore.proto \
    snix/castore/protos/rpc_directory.proto

  ${pkgs.protobuf}/bin/protoc \
    --include_imports \
    --include_source_info \
    -I $out \
    -I ${pkgs.protobuf}/include \
    -o $out/store/protos/snix.store.v1.bin \
    snix/store/protos/pathinfo.proto \
    snix/store/protos/rpc_pathinfo.proto

  ${pkgs.protobuf}/bin/protoc \
    --include_imports \
    --include_source_info \
    -I $out \
    -I ${pkgs.protobuf}/include \
    -o $out/build/protos/snix.build.v1.bin \
    snix/build/protos/build.proto \
    snix/build/protos/rpc_build.proto

  cat > $out/castore/build.rs <<'EOF'
  use std::{fs, io::Result, path::PathBuf};

  const DESCRIPTOR_SET: &str = "snix.castore.v1.bin";

  fn descriptor_output_path() -> Option<PathBuf> {
      #[cfg(feature = "tonic-reflection")]
      {
          let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
          return Some(out_dir.join(DESCRIPTOR_SET));
      }

      #[cfg(not(feature = "tonic-reflection"))]
      {
          None
      }
  }

  fn configured_builder() -> tonic_build::Builder {
      tonic_build::configure()
          .build_server(true)
          .build_client(true)
          .emit_rerun_if_changed(false)
          .bytes(["."])
          .type_attribute(".", "#[derive(Eq, Hash)]")
  }

  fn pregenerated_descriptor_path() -> PathBuf {
      PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
          .join("protos")
          .join(DESCRIPTOR_SET)
  }

  fn compile_from_pregenerated() -> Result<bool> {
      let descriptor_path = pregenerated_descriptor_path();
      if !descriptor_path.is_file() {
          return Ok(false);
      }

      let empty: &[&str] = &[];
      configured_builder()
          .file_descriptor_set_path(&descriptor_path)
          .skip_protoc_run()
          .compile_protos(empty, empty)?;

      if let Some(output_path) = descriptor_output_path() {
          let _ = fs::copy(&descriptor_path, output_path)?;
      }

      Ok(true)
  }

  fn proto_root() -> String {
      match std::env::var_os("PROTO_ROOT") {
          Some(proto_root) => proto_root.to_str().unwrap().to_owned(),
          None => "../..".to_string(),
      }
  }

  fn main() -> Result<()> {
      if compile_from_pregenerated()? {
          return Ok(());
      }

      let mut builder = configured_builder();
      if let Some(output_path) = descriptor_output_path() {
          builder = builder.file_descriptor_set_path(output_path);
      }

      builder.compile_protos(
          &[
              "snix/castore/protos/castore.proto",
              "snix/castore/protos/rpc_blobstore.proto",
              "snix/castore/protos/rpc_directory.proto",
          ],
          &[proto_root()],
      )?;

      Ok(())
  }
EOF

  cat > $out/store/build.rs <<'EOF'
  use std::{fs, io::Result, path::PathBuf};

  const DESCRIPTOR_SET: &str = "snix.store.v1.bin";

  fn descriptor_output_path() -> Option<PathBuf> {
      #[cfg(feature = "tonic-reflection")]
      {
          let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
          return Some(out_dir.join(DESCRIPTOR_SET));
      }

      #[cfg(not(feature = "tonic-reflection"))]
      {
          None
      }
  }

  fn configured_builder() -> tonic_build::Builder {
      tonic_build::configure()
          .build_server(true)
          .build_client(true)
          .emit_rerun_if_changed(false)
          .bytes(["."])
          .extern_path(".snix.castore.v1", "::snix_castore::proto")
  }

  fn pregenerated_descriptor_path() -> PathBuf {
      PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
          .join("protos")
          .join(DESCRIPTOR_SET)
  }

  fn compile_from_pregenerated() -> Result<bool> {
      let descriptor_path = pregenerated_descriptor_path();
      if !descriptor_path.is_file() {
          return Ok(false);
      }

      let empty: &[&str] = &[];
      configured_builder()
          .file_descriptor_set_path(&descriptor_path)
          .skip_protoc_run()
          .compile_protos(empty, empty)?;

      if let Some(output_path) = descriptor_output_path() {
          let _ = fs::copy(&descriptor_path, output_path)?;
      }

      Ok(true)
  }

  fn proto_root() -> String {
      match std::env::var_os("PROTO_ROOT") {
          Some(proto_root) => proto_root.to_str().unwrap().to_owned(),
          None => "../..".to_string(),
      }
  }

  fn main() -> Result<()> {
      if compile_from_pregenerated()? {
          return Ok(());
      }

      let mut builder = configured_builder();
      if let Some(output_path) = descriptor_output_path() {
          builder = builder.file_descriptor_set_path(output_path);
      }

      builder.compile_protos(
          &[
              "snix/store/protos/pathinfo.proto",
              "snix/store/protos/rpc_pathinfo.proto",
          ],
          &[proto_root()],
      )?;

      Ok(())
  }
EOF

  cat > $out/build/build.rs <<'EOF'
  use std::{fs, io::Result, path::PathBuf};

  const DESCRIPTOR_SET: &str = "snix.build.v1.bin";

  fn descriptor_output_path() -> Option<PathBuf> {
      #[cfg(feature = "tonic-reflection")]
      {
          let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
          return Some(out_dir.join(DESCRIPTOR_SET));
      }

      #[cfg(not(feature = "tonic-reflection"))]
      {
          None
      }
  }

  fn configured_builder() -> tonic_build::Builder {
      tonic_build::configure()
          .build_server(true)
          .build_client(true)
          .emit_rerun_if_changed(false)
          .bytes(["."])
          .extern_path(".snix.castore.v1", "::snix_castore::proto")
  }

  fn pregenerated_descriptor_path() -> PathBuf {
      PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
          .join("protos")
          .join(DESCRIPTOR_SET)
  }

  fn compile_from_pregenerated() -> Result<bool> {
      let descriptor_path = pregenerated_descriptor_path();
      if !descriptor_path.is_file() {
          return Ok(false);
      }

      let empty: &[&str] = &[];
      configured_builder()
          .file_descriptor_set_path(&descriptor_path)
          .skip_protoc_run()
          .compile_protos(empty, empty)?;

      if let Some(output_path) = descriptor_output_path() {
          let _ = fs::copy(&descriptor_path, output_path)?;
      }

      Ok(true)
  }

  fn proto_root() -> String {
      match std::env::var_os("PROTO_ROOT") {
          Some(proto_root) => proto_root.to_str().unwrap().to_owned(),
          None => "../..".to_string(),
      }
  }

  fn main() -> Result<()> {
      if compile_from_pregenerated()? {
          return Ok(());
      }

      let mut builder = configured_builder();
      if let Some(output_path) = descriptor_output_path() {
          builder = builder.file_descriptor_set_path(output_path);
      }

      builder.compile_protos(
          &[
              "snix/build/protos/build.proto",
              "snix/build/protos/rpc_build.proto",
          ],
          &[proto_root()],
      )?;

      Ok(())
  }
EOF

  # Strip write bits to match Nix store conventions
  chmod -R a-w $out
''
