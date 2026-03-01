# ncurses - Terminal control library for Redox OS
#
# ncurses (new curses) is a programming library providing an API that allows
# the programmer to write text-based user interfaces (TUI). It's a dependency
# for bash, vim, htop, and many other terminal applications.
#
# The only Redox-specific patch adds `redox*` to the configure OS detection.
#
# Source: https://ftp.gnu.org/gnu/ncurses/ncurses-6.4.tar.gz
# Output: static libraries (libncurses.a, libpanel.a, libform.a, libmenu.a) + headers

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  ...
}:

let
  mkCLibrary = import ./mk-c-library.nix {
    inherit
      pkgs
      lib
      redoxTarget
      relibc
      ;
  };

  version = "6.4";

  src = pkgs.fetchurl {
    url = "https://ftp.gnu.org/gnu/ncurses/ncurses-${version}.tar.gz";
    hash = "sha256-aTEoPZrIfFBz8wtikMTHXyFjK7T8NgOsgQCBK+0kgVk=";
  };

  # Redox patch: add redox* to configure's OS detection case statement
  # Use sed in preConfigure instead of a patch file to avoid Nix interpolation issues
  # with shell variables like ${LD_RPATH_OPT} in the configure script

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "ncurses-${version}-src";
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.gnutar
      pkgs.gzip
    ];
    installPhase = ''
      mkdir -p $out
      tar xf ${src} -C $out --strip-components=1
    '';
  };

in
mkCLibrary.mkAutotools {
  pname = "redox-ncurses";
  inherit version;
  src = extractedSrc;

  configureFlags = [
    "--disable-db-install"
    "--disable-stripping"
    "--without-ada"
    "--without-manpages"
    "--without-tests"
    "--without-shared"
    "--without-cxx"
    "--without-cxx-binding"
    "--disable-widec"
    "--enable-pc-files"
    "--with-pkg-config-libdir=$out/lib/pkgconfig"
  ];

  preConfigure = ''
    # Apply Redox patch: add redox* to OS case statement in configure
    sed -i 's/(linux\*|gnu\*|k\*bsd\*-gnu)/(linux*|gnu*|k*bsd*-gnu|redox*)/' configure
    grep -q 'redox' configure || { echo "ERROR: Redox patch failed"; exit 1; }

    # Override CC with the wrapper that handles CRT files.
    # Without this, configure's link tests fail (e.g., getopt, getenv)
    # because -nostdlib prevents libc linking.
    export CC="${mkCLibrary.ccWrapper}"
    export CXX="${mkCLibrary.cxxWrapper}"
    export LDFLAGS="--target=${redoxTarget} --sysroot=${relibc}/${redoxTarget} -L${relibc}/${redoxTarget}/lib -static -fuse-ld=lld"

    # Override ac_cv to avoid configure tests that fail in cross-compilation
    export ac_cv_func_mkstemp=yes

    # Create stub man files (--without-manpages doesn't fully prevent references)
    mkdir -p man
    touch man/man_db.renames.in man/MKncu_config.in
  '';

  postInstall = ''
    # Symlink curses.h -> ncurses.h for compat
    if [ -d $out/include/ncurses ]; then
      for h in $out/include/ncurses/*.h; do
        ln -sf "ncurses/$(basename $h)" "$out/include/$(basename $h)" 2>/dev/null || true
      done
    fi

    # Verify
    test -f $out/lib/libncurses.a || { echo "ERROR: libncurses.a not built"; exit 1; }
    echo "ncurses libraries:"
    ls -la $out/lib/lib*.a
  '';

  meta = with lib; {
    description = "Terminal control library for Redox OS";
    homepage = "https://invisible-island.net/ncurses/";
    license = licenses.mit;
  };
}
