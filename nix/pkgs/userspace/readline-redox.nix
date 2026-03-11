# readline - Line editing library for Redox OS
#
# GNU readline provides a set of functions for use by applications that
# allow users to edit command lines as they are typed in. It's used by
# bash, python, and many other interactive applications.
#
# The only Redox-specific patch adds `redox*` to config.sub's OS detection.
#
# Depends on: ncurses
# Source: https://ftp.gnu.org/gnu/readline/readline-7.0.tar.gz
# Output: libreadline.a, libhistory.a + headers

{
  pkgs,
  lib,
  redoxTarget,
  relibc,
  redox-ncurses,
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

  version = "7.0";

  src = pkgs.fetchurl {
    url = "https://ftp.gnu.org/gnu/readline/readline-${version}.tar.gz";
    hash = "sha256-dQ1DcYUob0CjaeHk9HZO2pMrlFm17JpzFig5PdPTIzQ=";
  };

  # Redox patch: add redox* to config.sub's OS detection
  redoxPatch = pkgs.writeText "readline-redox.patch" ''
    --- a/support/config.sub
    +++ b/support/config.sub
    @@ -1351,7 +1351,7 @@
     	# The portable systems comes first.
     	# Each alternative MUST END IN A *, to match a version number.
     	# -sysv* is not here because it comes later, after sysvr4.
    -	-gnu* | -bsd* | -mach* | -minix* | -genix* | -ultrix* | -irix* \
    +	-gnu* | -bsd* | -mach* | -minix* | -genix* | -ultrix* | -irix* | -redox* \
     	      | -*vms* | -sco* | -esix* | -isc* | -aix* | -cnk* | -sunos | -sunos[34]*\
     	      | -hpux* | -unos* | -osf* | -luna* | -dgux* | -auroraux* | -solaris* \
     	      | -sym* | -kopensolaris* | -plan9* \
  '';

  extractedSrc = pkgs.stdenv.mkDerivation {
    name = "readline-${version}-src";
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
  pname = "redox-readline";
  inherit version;
  src = extractedSrc;
  buildInputs = [ redox-ncurses ];

  configureFlags = [
    "--disable-shared"
    "--with-curses"
  ];

  preConfigure = ''
        # Apply Redox config.sub patch
        patch -p1 < ${redoxPatch} || true

        # Create stub doc/Makefile.in (not always present in the tarball)
        mkdir -p doc
        if [ ! -f doc/Makefile.in ]; then
          cat > doc/Makefile.in << 'DOCEOF'
    all:
    install:
    clean:
    distclean:
  DOCEOF
        fi

        # Use CC wrapper for working link tests
        export CC="${mkCLibrary.ccWrapper}"
        export CXX="${mkCLibrary.cxxWrapper}"
        export LDFLAGS="--target=${redoxTarget} --sysroot=${relibc}/${redoxTarget} -L${relibc}/${redoxTarget}/lib -static -fuse-ld=lld"
  '';

  postInstall = ''
    # Verify
    test -f $out/lib/libreadline.a || { echo "ERROR: libreadline.a not built"; exit 1; }
    test -f $out/lib/libhistory.a  || { echo "ERROR: libhistory.a not built"; exit 1; }
    echo "readline libraries:"
    ls -la $out/lib/lib*.a
  '';

  meta = with lib; {
    description = "GNU readline line editing library for Redox OS";
    homepage = "https://tiswww.case.edu/php/chet/readline/rltop.html";
    license = licenses.gpl3Plus;
  };
}
