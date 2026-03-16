# Root filesystem tree derivation
# Assembles the complete root filesystem with packages, configuration files,
# and system setup. Uses external tools for ELF fixing and manifest hashing.

{ hostPkgs, lib, cfg, inputs, allGeneratedFiles, initScripts, binaryCache, assertionCheck, warningCheck, fix-elf-palign, hash-manifest }:

let
  # Shell helpers for rootTree
  mkDirs =
    dirs:
    lib.concatStringsSep "\n" (
      builtins.map (dir: "mkdir -p $out${dir}") (builtins.filter (d: d != null) dirs)
    );

  mkDevSymlinks = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: target: "ln -sf ${target} $out/dev/${name}") (
      inputs.filesystem.devSymlinks or { }
    )
  );

  mkSpecialSymlinks = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: target:
      let
        dir = builtins.dirOf name;
      in
      ''
        ${lib.optionalString (dir != "." && dir != "/") "mkdir -p $out/${dir}"}
        ln -sf ${target} $out/${name}
      ''
    ) (inputs.filesystem.specialSymlinks or { })
  );

  # Boot-essential packages: flat-copied to /bin/ for init scripts and early boot
  mkBootPackages = lib.concatStringsSep "\n" (
    builtins.map (pkg: ''
      if [ -d "${pkg}/bin" ]; then
        for f in ${pkg}/bin/*; do
          [ -e "$f" ] || continue
          cp "$f" $out/bin/$(basename "$f") 2>/dev/null || true
          cp "$f" $out/usr/bin/$(basename "$f") 2>/dev/null || true
        done
      fi
      # Data packages (e.g. orbdata): merge ui/ and usr/ trees into root filesystem.
      # Orbital expects /ui/orbital.toml, /ui/fonts/, /ui/icons/, etc.
      # Use "source/." to merge contents into existing directories rather than
      # nesting (cp -r pkg/usr $out/usr would create $out/usr/usr/ if $out/usr exists).
      if [ -d "${pkg}/ui" ]; then
        mkdir -p $out/ui
        cp -rn "${pkg}/ui/." "$out/ui/"
      fi
      if [ -d "${pkg}/usr" ]; then
        mkdir -p $out/usr
        cp -rn "${pkg}/usr/." "$out/usr/"
      fi
    '') cfg.bootPackages
  );

  # All packages: stored in /nix/store/<hash>-<name>/ with content-addressed paths
  # Copies bin/, lib/, sysroot/, include/, share/, and etc/ directories.
  # Most packages only have bin/; toolchain packages (rustc, LLVM) need lib/.
  # selfHostingPackages and isSelfHostingPkg are defined above alongside
  # bootPackages — both use derivation references, not name strings.
  mkStorePackages = lib.concatStringsSep "\n" (
    builtins.map (pkg: ''
      pkg_store="$out/nix/store/${cfg.pkgStoreName pkg}"
      mkdir -p "$pkg_store"
      # Always copy bin/
      if [ -d "${pkg}/bin" ]; then
        cp -r "${pkg}/bin" "$pkg_store/bin"
      fi
      ${lib.optionalString (cfg.isSelfHostingPkg pkg) ''
        # Self-hosting package: also copy lib/, sysroot/, include/, share/, etc/
        for subdir in lib sysroot include share etc; do
          if [ -d "${pkg}/$subdir" ]; then
            cp -r "${pkg}/$subdir" "$pkg_store/$subdir"
          fi
        done
      ''}
    '') cfg.allPackages
  );

  # System profile: /nix/system/profile/bin/ with symlinks to store paths.
  # This is what gets rebuilt on generation switch — binaries appear/disappear.
  # Also creates lib/ symlinks for packages that need runtime libraries (e.g., rustc).
  mkSystemProfile = ''
    mkdir -p $out/nix/system/profile/bin
    ${lib.concatStringsSep "\n" (
      builtins.map (pkg: ''
        if [ -d "$out/nix/store/${cfg.pkgStoreName pkg}/bin" ]; then
          for f in $out/nix/store/${cfg.pkgStoreName pkg}/bin/*; do
            [ -e "$f" ] || continue
            bin_name=$(basename "$f")
            ln -sf "/nix/store/${cfg.pkgStoreName pkg}/bin/$bin_name" \
              "$out/nix/system/profile/bin/$bin_name"
          done
        fi
        ${lib.optionalString (cfg.isSelfHostingPkg pkg) ''
          # Symlink lib/ for self-hosting packages with runtime libraries (rustc, LLVM)
          if [ -d "$out/nix/store/${cfg.pkgStoreName pkg}/lib" ]; then
            mkdir -p $out/nix/system/profile/lib
            for f in $out/nix/store/${cfg.pkgStoreName pkg}/lib/*; do
              [ -e "$f" ] || [ -L "$f" ] || continue
              lib_name=$(basename "$f")
              ln -sf "/nix/store/${cfg.pkgStoreName pkg}/lib/$lib_name" \
                "$out/nix/system/profile/lib/$lib_name" 2>/dev/null || true
            done
          fi
        ''}
      '') cfg.managedPackages
    )}
  '';

  mkGeneratedFiles = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      path: file:
      let
        dir = builtins.dirOf path;
        storeFile =
          if file ? source then
            file.source # Pre-built store file (e.g., manifest.json)
          else
            hostPkgs.writeText (builtins.replaceStrings [ "/" ] [ "-" ] path) file.text;
      in
      ''
        ${lib.optionalString (dir != "." && dir != "/") "mkdir -p $out/${dir}"}
        cp ${storeFile} $out/${path}
        chmod ${file.mode or "0644"} $out/${path}
      ''
    ) allGeneratedFiles
  );

in

hostPkgs.runCommand "redox-root-tree"
  {
    nativeBuildInputs = [
      fix-elf-palign
      hash-manifest
    ];
  }
  ''
    ${assert assertionCheck; assert warningCheck; ""}
    ${mkDirs cfg.allDirectories}
    mkdir -p $out/dev
    ${mkDevSymlinks}
    ${mkSpecialSymlinks}
    # Boot-essential packages in /bin/ (survive generation switches)
    ${mkBootPackages}

    # All packages in /nix/store/ with content-addressed paths
    ${mkStorePackages}

    # System profile with symlinks to managed (non-boot) packages
    ${mkSystemProfile}

    # Self-hosting: create well-known sysroot path
    ${lib.optionalString cfg.hasSelfHosting ''
      echo "Setting up self-hosting sysroot..."
      mkdir -p $out/usr/lib
      # Create /usr/lib/redox-sysroot → /nix/store/<hash>-redox-sysroot/sysroot
      ln -sf "/nix/store/${cfg.pkgStoreName cfg.sysrootPkg}/sysroot" \
        $out/usr/lib/redox-sysroot

      # Dynamic linker: ld64.so.1 must be at /lib/ for the kernel's ELF loader
      # Also provide libc.so for dynamically linked binaries
      mkdir -p $out/lib
      cp "/nix/store/${cfg.pkgStoreName cfg.sysrootPkg}/lib/ld64.so.1" $out/lib/ld64.so.1
      chmod 555 $out/lib/ld64.so.1
      cp "/nix/store/${cfg.pkgStoreName cfg.sysrootPkg}/lib/libc.so" $out/lib/libc.so
      chmod 555 $out/lib/libc.so
      ln -sf libc.so $out/lib/libc.so.6
      # libstdc++.so.6 shim (libc++ with libstdc++ soname, for librustc_driver.so)
      ${lib.optionalString (cfg.libstdcxxShimPkg != null) ''
        if [ -f "$out/nix/store/${cfg.pkgStoreName cfg.libstdcxxShimPkg}/lib/libstdc++.so.6" ]; then
          cp "$out/nix/store/${cfg.pkgStoreName cfg.libstdcxxShimPkg}/lib/libstdc++.so.6" $out/lib/libstdc++.so.6
          chmod 555 $out/lib/libstdc++.so.6
          # Also copy alongside librustc_driver.so for RUNPATH=$ORIGIN resolution
          ${lib.optionalString (cfg.rustcPkg != null) ''
            chmod u+w "$out/nix/store/${cfg.pkgStoreName cfg.rustcPkg}/lib"
            cp "$out/nix/store/${cfg.pkgStoreName cfg.libstdcxxShimPkg}/lib/libstdc++.so.6" \
              "$out/nix/store/${cfg.pkgStoreName cfg.rustcPkg}/lib/libstdc++.so.6"
            chmod 555 "$out/nix/store/${cfg.pkgStoreName cfg.rustcPkg}/lib/libstdc++.so.6"
          ''}
        fi
      ''}

      # LD_LIBRARY_PATH for rustc's dynamic libs
      # rustc needs librustc_driver.so + proc-macro .so files at runtime
      mkdir -p $out/usr/lib/rustc
      if [ -d "$out/nix/store/${cfg.pkgStoreName cfg.rustcPkg}/lib" ]; then
        for f in $out/nix/store/${cfg.pkgStoreName cfg.rustcPkg}/lib/*.so; do
          [ -e "$f" ] || continue
          lib_name=$(basename "$f")
          ln -sf "/nix/store/${cfg.pkgStoreName cfg.rustcPkg}/lib/$lib_name" \
            "$out/usr/lib/rustc/$lib_name"
        done
      fi

      # Fix p_align=0 in ELF program headers (relibc ld_so bug workaround).
      echo "Fixing p_align=0 in ELF program headers..."
      fix-elf-palign $out
    ''}

    ${mkGeneratedFiles}

    # Extra paths: copy arbitrary store derivations to target directories
    ${lib.concatStringsSep "\n" (
      builtins.map (ep: ''
        echo "Copying extra path to ${ep.target}..."
        mkdir -p "$out/${ep.target}"
        # Use /. instead of /* to include dotfiles (.cargo/, etc.)
        cp -r ${ep.source}/. "$out/${ep.target}/"
      '') (inputs.filesystem.extraPaths or [ ])
    )}

    # Include local binary cache if configured
    ${lib.optionalString cfg.hasBinaryCache ''
      echo "Including binary cache (${toString (builtins.length (builtins.attrNames cfg.binaryCachePackages))} packages)..."
      mkdir -p $out/nix/cache
      cp -r ${binaryCache.cache}/* $out/nix/cache/
    ''}

    # Compute file hashes, generation buildHash, and seed generations dir.
    # The base manifest was written above; now we add:
    #   1. "files" key with SHA256 hashes of every rootTree file
    #   2. "generation.buildHash" — SHA256 of the sorted file inventory
    #   3. /etc/redox-system/generations/1/ with a copy of the manifest
    hash-manifest $out

    echo "Root tree: $(find $out -type f | wc -l) files, $(find $out/bin -type f 2>/dev/null | wc -l) binaries"
  ''