# sqlite3 - Self-contained SQL database engine for Redox OS
#
# SQLite is the most widely deployed database engine in the world.
# The amalgamation build (single sqlite3.c + sqlite3.h) makes cross-compilation
# trivially easy — no configure step needed.
#
# No Redox-specific patches needed for the library.
#
# Source: https://www.sqlite.org/download.html (amalgamation)
# Output: libsqlite3.a + sqlite3.h + pkg-config

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

  # SQLite version: 3.49.1 (2025-02-18)
  # URL encodes version as 3490100 (3*1000000 + 49*10000 + 01*100 + 00)
  version = "3.49.1";
  versionId = "3490100";

  src = pkgs.fetchurl {
    url = "https://www.sqlite.org/2025/sqlite-amalgamation-${versionId}.zip";
    hash = "sha256-bOvR2EA/xYww6Tk5skbz5uWNB2WlzVBUbxbAD9gF0sM=";
  };

in
mkCLibrary.mkLibrary {
  pname = "redox-sqlite3";
  inherit version;
  inherit src;

  nativeBuildInputs = [ pkgs.unzip ];

  configurePhase = ''
    runHook preConfigure

    unzip ${src}
    cd sqlite-amalgamation-${versionId}
    chmod -R u+w .

    ${mkCLibrary.crossEnvSetup}

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Build the amalgamation — single file, no configure needed
    $CC $CFLAGS \
      -DSQLITE_OMIT_LOAD_EXTENSION \
      -DSQLITE_THREADSAFE=0 \
      -DSQLITE_OS_UNIX=1 \
      -c sqlite3.c -o sqlite3.o

    $AR rcs libsqlite3.a sqlite3.o
    $RANLIB libsqlite3.a

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/include $out/lib/pkgconfig

    cp libsqlite3.a $out/lib/
    cp sqlite3.h sqlite3ext.h $out/include/

    # Create pkg-config file
    cat > $out/lib/pkgconfig/sqlite3.pc << EOF
    prefix=$out
    libdir=''${prefix}/lib
    includedir=''${prefix}/include

    Name: SQLite
    Description: SQL database engine
    Version: ${version}
    Libs: -L''${libdir} -lsqlite3
    Cflags: -I''${includedir}
  EOF

    # Verify
    test -f $out/lib/libsqlite3.a || { echo "ERROR: libsqlite3.a not built"; exit 1; }
    echo "sqlite3 built:"
    ls -la $out/lib/libsqlite3.a

    runHook postInstall
  '';

  meta = with lib; {
    description = "Self-contained SQL database engine for Redox OS";
    homepage = "https://www.sqlite.org/";
    license = licenses.publicDomain;
  };
}
