# Redox OS Kernel build
{
  lib,
  stdenv,
  fetchFromGitLab,
  rustToolchain,
  target,
  gnumake,
  nasm,
}:
stdenv.mkDerivation rec {
  pname = "redox-kernel";
  version = "unstable-2025-01-01";

  src = fetchFromGitLab {
    owner = "redox-os";
    repo = "kernel";
    domain = "gitlab.redox-os.org";
    rev = "master";
    # TODO: Pin to specific revision
    sha256 = lib.fakeSha256;
  };

  nativeBuildInputs = [
    rustToolchain
    gnumake
    nasm
  ];

  # Set up environment for kernel build
  RUST_TARGET_PATH = "${src}";
  TARGET = target;

  buildPhase = ''
    # Build kernel with proper target
    export RUSTUP_TOOLCHAIN="${rustToolchain}"
    export RUST_SRC_PATH="${rustToolchain}/lib/rustlib/src/rust/library"

    make -f Makefile
  '';

  installPhase = ''
    mkdir -p $out/boot
    cp kernel $out/boot/
    cp kernel.sym $out/boot/ || true
  '';

  meta = with lib; {
    description = "Redox OS Kernel";
    homepage = "https://gitlab.redox-os.org/redox-os/kernel";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
