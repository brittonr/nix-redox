# Build Module (/build)
#
# Single consolidated build module that produces all build outputs.
# In adios, inputs give module OPTIONS (not impl outputs), so this
# module reads all config and produces rootTree, initfs, diskImage,
# toplevel, espImage, redoxfsImage.
#
# Composable disk image building inspired by NixBSD's
# make-disk-image.nix + make-partition-image.nix architecture.

adios:

{
  name = "build";

  # No sub-modules — everything is built here

  inputs = {
    pkgs = {
      path = "/pkgs";
    };
    boot = {
      path = "/boot";
    };
    hardware = {
      path = "/hardware";
    };
    networking = {
      path = "/networking";
    };
    environment = {
      path = "/environment";
    };
    filesystem = {
      path = "/filesystem";
    };
    graphics = {
      path = "/graphics";
    };
    services = {
      path = "/services";
    };
    users = {
      path = "/users";
    };
    virtualisation = {
      path = "/virtualisation";
    };
  };

  impl =
    { inputs }:
    let
      lib = inputs.pkgs.nixpkgsLib;
      hostPkgs = inputs.pkgs.hostPkgs;
      pkgs = inputs.pkgs.pkgs;
      # inputs gives OPTIONS only, not impl output — compute redoxLib here
      redoxLib = import ../../lib.nix {
        inherit lib;
        pkgs = hostPkgs;
      };

      # ===== SHARED COMPUTATIONS =====

      graphicsEnabled = inputs.graphics.enable or false;
      networkingEnabled = inputs.networking.enable or false;
      usbEnabled = (inputs.hardware.usbEnable or false) || graphicsEnabled;
      audioEnabled = inputs.hardware.audioEnable or false;
      initfsEnableGraphics = (inputs.boot.initfsEnableGraphics or false) || graphicsEnabled;

      # Compute all drivers
      allDrivers = lib.unique (
        (inputs.hardware.storageDrivers or [ ])
        ++ (inputs.hardware.networkDrivers or [ ])
        ++ (lib.optionals graphicsEnabled (inputs.hardware.graphicsDrivers or [ ]))
        ++ (lib.optionals audioEnabled (inputs.hardware.audioDrivers or [ ]))
        ++ (lib.optional usbEnabled "xhcid")
        ++ (inputs.boot.initfsExtraDrivers or [ ])
      );

      # PCI driver registry
      pciRegistry = {
        ahcid = [
          {
            name = "AHCI";
            class = "1";
            subclass = "6";
          }
        ];
        ided = [
          {
            name = "IDE";
            class = "1";
            subclass = "1";
          }
        ];
        nvmed = [
          {
            name = "NVMe";
            class = "1";
            subclass = "8";
          }
        ];
        virtio-blkd = [
          {
            name = "VirtIO Block Legacy";
            vendor = "0x1AF4";
            device = "0x1001";
          }
          {
            name = "VirtIO Block Modern";
            vendor = "0x1AF4";
            device = "0x1042";
          }
        ];
        e1000d = [
          {
            name = "Intel E1000";
            class = "0x02";
            vendor = "0x8086";
            device = "0x100e";
          }
        ];
        virtio-netd = [
          {
            name = "VirtIO Net Legacy";
            class = "0x02";
            vendor = "0x1AF4";
            device = "0x1000";
          }
          {
            name = "VirtIO Net Modern";
            class = "0x02";
            vendor = "0x1AF4";
            device = "0x1041";
          }
        ];
        virtio-gpud = [
          {
            name = "VirtIO GPU";
            class = "0x03";
            vendor = "0x1AF4";
            device = "0x1050";
          }
        ];
        bgad = [
          {
            name = "Bochs VGA";
            class = "0x03";
            vendor = "0x1234";
            device = "0x1111";
          }
        ];
        ihdad = [
          {
            name = "Intel HD Audio ICH6";
            class = "0x04";
            subclass = "0x03";
            vendor = "0x8086";
            device = "0x2668";
          }
          {
            name = "Intel HD Audio ICH9";
            class = "0x04";
            subclass = "0x03";
            vendor = "0x8086";
            device = "0x293e";
          }
        ];
        ac97d = [
          {
            name = "AC97";
            class = "0x04";
            subclass = "0x01";
            vendor = "0x8086";
            device = "0x2415";
          }
        ];
        xhcid = [
          {
            name = "USB xHCI";
            class = "0x0C";
            subclass = "0x03";
          }
        ];
      };

      pcidDrivers = builtins.concatLists (
        builtins.map (drv: builtins.map (entry: entry // { command = drv; }) (pciRegistry.${drv} or [ ])) (
          lib.unique allDrivers
        )
      );

      # Core daemons for initfs
      coreDaemons = [
        "init"
        "logd"
        "ramfs"
        "randd"
        "zerod"
        "pcid"
        "pcid-spawner"
        "lived"
        "acpid"
        "hwd"
        "rtcd"
        "ptyd"
        "ipcd"
      ]
      ++ lib.optional initfsEnableGraphics "ps2d"
      ++ lib.optional networkingEnabled "smolnetd";

      initfsDaemons =
        (lib.optionals initfsEnableGraphics [
          "vesad"
          "inputd"
          "fbbootlogd"
          "fbcond"
        ])
        ++ (lib.optionals usbEnabled [
          "xhcid"
          "usbhubd"
          "usbhidd"
        ]);

      allDaemons = lib.unique (coreDaemons ++ initfsDaemons ++ (inputs.boot.initfsExtraBinaries or [ ]));

      # Collect all system packages
      allPackages =
        (inputs.environment.systemPackages or [ ])
        ++ (lib.optional (pkgs ? base) pkgs.base)
        ++ (lib.optional (networkingEnabled && pkgs ? netutils) pkgs.netutils)
        ++ (lib.optional (networkingEnabled && pkgs ? netcfg-setup) pkgs.netcfg-setup)
        ++ (lib.optionals graphicsEnabled (
          lib.optional (pkgs ? orbital) pkgs.orbital
          ++ lib.optional (pkgs ? orbdata) pkgs.orbdata
          ++ lib.optional (pkgs ? orbterm) pkgs.orbterm
          ++ lib.optional (pkgs ? orbutils) pkgs.orbutils
        ));

      # Check if userutils (getty, login) is installed on rootFS
      # This determines whether init.rc can use getty for serial console login
      # or must fall back to running the shell directly via startup.sh
      userutilsInstalled =
        let
          uu = pkgs.userutils or null;
        in
        uu != null && builtins.any (p: p == uu) allPackages;

      # Collect all directories
      homeDirectories = lib.filter (d: d != null) (
        lib.mapAttrsToList (name: user: if user.createHome or false then user.home else null) (
          inputs.users.users or { }
        )
      );

      allDirectories =
        (inputs.filesystem.extraDirectories or [ ])
        ++ homeDirectories
        ++ (lib.optional networkingEnabled "/var/log");

      # User for serial console
      nonRootUsers = lib.filterAttrs (name: user: (user.uid or 0) > 0) (inputs.users.users or { });
      defaultUser =
        if nonRootUsers != { } then
          let
            name = builtins.head (builtins.attrNames nonRootUsers);
          in
          {
            inherit name;
            home = nonRootUsers.${name}.home or "/home/${name}";
          }
        else
          {
            name = "root";
            home = "/root";
          };

      # ===== GENERATED FILES =====

      # Environment: /etc/profile
      varLines = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "export ${name} ${value}") (inputs.environment.variables or { })
      );
      aliasLines = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: ''alias ${name} = "${value}"'') (
          inputs.environment.shellAliases or { }
        )
      );
      graphicsVarLines = lib.optionalString graphicsEnabled ''
        export ORBITAL_RESOLUTION ${inputs.graphics.resolution or "1024x768"}
        export DISPLAY :0
      '';
      graphicsAliasLines = lib.optionalString graphicsEnabled ''
        alias gui = "orbital"
        alias term = "orbterm"
      '';
      profileContent = ''
        # RedoxOS System Profile (generated by adios module system)
        ${varLines}
        ${graphicsVarLines}
        ${aliasLines}
        ${graphicsAliasLines}
        ${inputs.environment.shellInit or ""}
      '';

      # Users: /etc/passwd, /etc/group, /etc/shadow
      passwdContent =
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: user:
            redoxLib.mkPasswdEntry {
              inherit name;
              inherit (user)
                uid
                gid
                home
                shell
                ;
              password = user.password or "";
              realname = user.realname or name;
            }
          ) (inputs.users.users or { })
        )
        + "\n";

      groupContent =
        lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: group:
            redoxLib.mkGroupEntry {
              inherit name;
              inherit (group) gid;
              members = group.members or [ ];
            }
          ) (inputs.users.groups or { })
        )
        + "\n";

      shadowContent =
        lib.concatStringsSep "\n" (lib.mapAttrsToList (name: _: "${name};") (inputs.users.users or { }))
        + "\n";

      # Services: init.toml, startup.sh
      initToml = ''
        [[services]]
        name = "shell"
        command = "/startup.sh"
        stdio = "debug"
        restart = false
      '';

      startupContent = "#!/bin/sh\n" + (inputs.services.startupScriptText or "/bin/ion\n");

      # Network interface resolution (for static config)
      firstIfaceName =
        let
          names = builtins.attrNames (inputs.networking.interfaces or { });
        in
        if names != [ ] then builtins.head names else null;
      firstIface =
        if firstIfaceName != null then inputs.networking.interfaces.${firstIfaceName} else null;

      # Collect all init scripts
      allInitScripts =
        (inputs.services.initScripts or { })
        // (lib.optionalAttrs networkingEnabled (
          {
            "10_net" = {
              text = "notify /bin/smolnetd";
              directory = "init.d";
            };
          }
          // (lib.optionalAttrs (inputs.networking.mode == "dhcp" || inputs.networking.mode == "auto") {
            "15_dhcp" = {
              text = "echo \"Starting DHCP client...\"\nnowait /bin/dhcpd-quiet";
              directory = "init.d";
            };
          })
          // (lib.optionalAttrs (inputs.networking.mode == "auto") {
            "16_netcfg" = {
              text = "nowait /bin/netcfg-setup auto";
              directory = "init.d";
            };
          })
          // (lib.optionalAttrs (inputs.networking.mode == "static" && firstIface != null) {
            "15_netcfg" = {
              # Interface config names (e.g. "cloud-hypervisor") are labels —
              # the actual Redox device is always eth0.
              text = "/bin/netcfg-setup static --interface eth0 --address ${firstIface.address} --gateway ${firstIface.gateway}";
              directory = "init.d";
            };
          })
          // (lib.optionalAttrs (inputs.networking.remoteShellEnable or false) {
            "17_remote_shell" = {
              text = "echo \"Starting remote shell on port ${
                toString (inputs.networking.remoteShellPort or 8023)
              }...\"\nnowait /bin/nc -l -e /bin/sh 0.0.0.0:${
                toString (inputs.networking.remoteShellPort or 8023)
              }";
              directory = "init.d";
            };
          })
        ))
        // (lib.optionalAttrs graphicsEnabled {
          "20_orbital" = {
            text =
              if pkgs ? orbutils then
                "export VT 1\nnowait /bin/orbital /bin/orblogin /bin/orbterm"
              else
                "export VT 1\nnowait /bin/orbital /bin/login";
            directory = "usr/lib/init.d";
          };
        });

      # Collect all generated files
      allGeneratedFiles = {
        "etc/profile" = {
          text = profileContent;
          mode = "0644";
        };
        "etc/ion/initrc" = {
          text = ''let PROMPT = "ion> "'';
          mode = "0644";
        };
        "etc/passwd" = {
          text = passwdContent;
          mode = "0644";
        };
        "etc/group" = {
          text = groupContent;
          mode = "0644";
        };
        "etc/shadow" = {
          text = shadowContent;
          mode = "0600";
        };
        "etc/init.toml" = {
          text = initToml;
          mode = "0644";
        };
        "startup.sh" = {
          text = startupContent;
          mode = "0755";
        };
      }
      // (lib.optionalAttrs networkingEnabled {
        "etc/net/dns" = {
          text = lib.concatStringsSep "\n" (inputs.networking.dns or [ ]);
          mode = "0644";
        };
        "etc/net/ip_router" = {
          text = inputs.networking.defaultRouter or "10.0.2.2";
          mode = "0644";
        };
      })
      // (lib.optionalAttrs
        (networkingEnabled && (inputs.networking.mode == "dhcp" || inputs.networking.mode == "auto"))
        {
          "bin/dhcpd-quiet" = {
            text = "#!/bin/ion\n/bin/dhcpd -v eth0 > /var/log/dhcpd.log";
            mode = "0755";
          };
        }
      )
      # Per-interface files
      // (builtins.foldl' (acc: entry: acc // entry) { } (
        lib.mapAttrsToList (name: iface: {
          "etc/net/${name}/ip" = {
            text = iface.address or "";
            mode = "0644";
          };
          "etc/net/${name}/netmask" = {
            text = iface.netmask or "255.255.255.0";
            mode = "0644";
          };
          "etc/net/${name}/gateway" = {
            text = iface.gateway or "";
            mode = "0644";
          };
        }) (inputs.networking.interfaces or { })
      ))
      # Init script files (raw initScripts + rendered structured services)
      // (builtins.listToAttrs (
        lib.mapAttrsToList (
          name: script:
          let
            dir = if (script.directory or "init.d") == "init.d" then "etc/init.d" else script.directory;
          in
          {
            name = "${dir}/${name}";
            value = {
              text = script.text;
              mode = "0755";
            };
          }
        ) allInitScriptsWithServices
      ));

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

      mkPackages = lib.concatStringsSep "\n" (
        builtins.map (pkg: ''
          if [ -d "${pkg}/bin" ]; then
            for f in ${pkg}/bin/*; do
              [ -e "$f" ] || continue
              cp "$f" $out/bin/$(basename "$f") 2>/dev/null || true
              cp "$f" $out/usr/bin/$(basename "$f") 2>/dev/null || true
            done
          fi
        '') allPackages
      );

      mkGeneratedFiles = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          path: file:
          let
            dir = builtins.dirOf path;
            storeFile = hostPkgs.writeText (builtins.replaceStrings [ "/" ] [ "-" ] path) file.text;
          in
          ''
            ${lib.optionalString (dir != "." && dir != "/") "mkdir -p $out/${dir}"}
            cp ${storeFile} $out/${path}
            chmod ${file.mode or "0644"} $out/${path}
          ''
        ) allGeneratedFiles
      );

      # ===== PCID TOML =====
      mkPcidEntry =
        {
          name ? null,
          class ? null,
          subclass ? null,
          vendor ? null,
          device ? null,
          command,
          ...
        }:
        let
          fmtVal =
            v:
            if v == null then
              null
            else if lib.hasPrefix "0x" v then
              v
            else if builtins.match "[0-9]+" v != null then
              v
            else
              ''"${v}"'';
          optLine =
            key: val:
            let
              f = fmtVal val;
            in
            lib.optionalString (f != null) "${key} = ${f}\n";
        in
        ''
          [[drivers]]
          ${optLine "name" name}${optLine "class" class}${optLine "subclass" subclass}${optLine "vendor" vendor}${optLine "device" device}command = ["/scheme/initfs/lib/drivers/${command}"]
        '';

      pcidToml =
        "# PCI drivers - generated by adios module system\n"
        + lib.concatStringsSep "\n" (builtins.map mkPcidEntry pcidDrivers);

      # ===== INIT.D SCRIPTS (numbered, new init system) =====
      # The new init daemon reads numbered scripts from /scheme/initfs/etc/init.d/
      # instead of a single init.rc file
      initScriptFiles = {
        "00_runtime" = ''
          # Core runtime daemons (SchemeDaemon binaries use 'scheme <name> <cmd>')
          export PATH /scheme/initfs/bin
          export LD_LIBRARY_PATH /scheme/initfs/lib
          export RUST_BACKTRACE 1
          rtcd
          scheme null nulld
          scheme zero zerod
          scheme rand randd
        '';

        "10_logging" = ''
          # Logging infrastructure
          scheme log logd
          stdio /scheme/log
          scheme logging ramfs logging
        '';

        # ptyd, ipcd, USB daemons are rootfs services started by
        # run.d /usr/lib/init.d /etc/init.d in 90_exit_initfs.
        # They are NOT part of the initfs boot sequence.

        "20_graphics" = lib.optionalString initfsEnableGraphics ''
          # Graphics and input (SchemeDaemons: inputd, fbbootlogd, fbcond)
          scheme input inputd
          notify vesad
          unset FRAMEBUFFER_ADDR FRAMEBUFFER_VIRT FRAMEBUFFER_WIDTH FRAMEBUFFER_HEIGHT FRAMEBUFFER_STRIDE
          scheme fbbootlog fbbootlogd
          inputd -A 1
          scheme fbcon fbcond 2
        '';

        "30_live" = ''
          # Live daemon (Daemon)
          notify lived
        '';

        "40_drivers" = ''
          # Hardware and PCI drivers
          ${lib.optionalString initfsEnableGraphics "notify ps2d"}
          notify hwd
          unset RSDP_ADDR RSDP_SIZE
          pcid-spawner --initfs
        '';

        "50_rootfs" = ''
          # Mount root filesystem
          redoxfs --uuid $REDOXFS_UUID file $REDOXFS_BLOCK
          unset REDOXFS_UUID REDOXFS_BLOCK REDOXFS_PASSWORD_ADDR REDOXFS_PASSWORD_SIZE
        '';

        "90_exit_initfs" = ''
          # Exit initfs and enter userspace
          cd /
          export PATH /usr/bin
          export LD_LIBRARY_PATH /usr/lib
          unset LD_LIBRARY_PATH
          run.d /usr/lib/init.d /etc/init.d
          echo ""
          echo "=========================================="
          echo "  Redox OS Boot Complete!"
          echo "=========================================="
          echo ""
          export TERM ${inputs.environment.variables.TERM or "xterm-256color"}
          export XDG_CONFIG_HOME /etc
          export HOME ${defaultUser.home}
          export USER ${defaultUser.name}
          export PATH ${inputs.environment.variables.PATH or "/bin:/usr/bin"}
          ${if userutilsInstalled then "/bin/getty debug:" else "/startup.sh"}
        '';
      };

      # ===== STRUCTURED SERVICE RENDERING =====
      # Render typed Service structs (from /services.services) into init script entries
      # These get merged with raw initScripts from /services.initScripts
      renderService =
        name: svc:
        if !(svc.enable or true) then
          null
        else
          {
            inherit name;
            value = {
              text =
                if svc.type == "scheme" then
                  "# ${svc.description}\nscheme ${svc.args} ${svc.command}"
                else if svc.type == "daemon" then
                  "# ${svc.description}\nnotify ${svc.command}${lib.optionalString (svc.args != "") " ${svc.args}"}"
                else if svc.type == "nowait" then
                  "# ${svc.description}\nnowait ${svc.command}${lib.optionalString (svc.args != "") " ${svc.args}"}"
                else
                  "# ${svc.description}\n${svc.command}${lib.optionalString (svc.args != "") " ${svc.args}"}";
              directory = if (svc.wantedBy or "rootfs") == "initfs" then "etc/init.d" else "usr/lib/init.d";
            };
          };

      renderedServices = builtins.listToAttrs (
        builtins.filter (x: x != null) (lib.mapAttrsToList renderService (inputs.services.services or { }))
      );

      # Merge raw initScripts with rendered structured services
      allInitScriptsWithServices = allInitScripts // renderedServices;

      # ===== COMPOSABLE DISK IMAGE BUILDERS =====
      mkEspImage = import ../../lib/make-esp-image.nix { inherit hostPkgs lib; };
      mkRedoxfsImage = import ../../lib/make-redoxfs-image.nix { inherit hostPkgs lib; };
      mkDiskImage = import ../../lib/make-disk-image.nix { inherit hostPkgs lib; };

      # ===== BUILD DERIVATIONS =====

      rootTree = hostPkgs.runCommand "redox-root-tree" { } ''
        ${mkDirs allDirectories}
        mkdir -p $out/dev
        ${mkDevSymlinks}
        ${mkSpecialSymlinks}
        ${mkPackages}
        ${mkGeneratedFiles}
        echo "Root tree: $(find $out -type f | wc -l) files, $(find $out/bin -type f 2>/dev/null | wc -l) binaries"
      '';

      initfs = hostPkgs.stdenv.mkDerivation {
        pname = "redox-initfs";
        version = "unstable";
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.initfsTools ];
        buildPhase = ''
          runHook preBuild
          mkdir -p initfs/{bin,lib/drivers,etc/{init.d,pcid.d,ion},usr/bin,usr/lib/drivers}

          ${lib.concatStringsSep "\n" (
            builtins.map (d: ''
              [ -f ${pkgs.base}/bin/${d} ] && cp ${pkgs.base}/bin/${d} initfs/bin/
            '') allDaemons
          )}

          cp ${pkgs.base}/bin/zerod initfs/bin/nulld
          cp ${pkgs.redoxfsTarget}/bin/redoxfs initfs/bin/
          cp ${pkgs.ion}/bin/ion initfs/bin/ion
          cp ${pkgs.ion}/bin/ion initfs/usr/bin/ion
          cp ${pkgs.ion}/bin/ion initfs/bin/sh
          cp ${pkgs.ion}/bin/ion initfs/usr/bin/sh

          ${lib.optionalString (pkgs ? netutils) ''
            [ -f ${pkgs.netutils}/bin/ifconfig ] && cp ${pkgs.netutils}/bin/ifconfig initfs/bin/
            [ -f ${pkgs.netutils}/bin/ping ] && cp ${pkgs.netutils}/bin/ping initfs/bin/
          ''}

          ${lib.optionalString (pkgs ? userutils) ''
            for bin in getty login; do
              [ -f ${pkgs.userutils}/bin/$bin ] && cp ${pkgs.userutils}/bin/$bin initfs/bin/
            done
          ''}

          ${lib.concatStringsSep "\n" (
            builtins.map (d: ''
              [ -f ${pkgs.base}/bin/${d} ] && cp -f ${pkgs.base}/bin/${d} initfs/lib/drivers/
            '') allDrivers
          )}

          ${lib.optionalString usbEnabled ''
            for drv in xhcid usbhubd usbhidd; do
              [ -f ${pkgs.base}/bin/$drv ] && cp -f ${pkgs.base}/bin/$drv initfs/lib/drivers/
            done
            for bin in usbhubd usbhidd; do
              [ -f ${pkgs.base}/bin/$bin ] && cp -f ${pkgs.base}/bin/$bin initfs/bin/
              [ -f ${pkgs.base}/bin/$bin ] && cp -f ${pkgs.base}/bin/$bin initfs/usr/lib/drivers/
            done
          ''}

          # Write pcid config to new location (etc/pcid.d/ instead of etc/pcid/)
          cat > initfs/etc/pcid.d/initfs.toml << 'PCID_EOF'
          ${pcidToml}
          PCID_EOF

          # Write numbered init.d scripts (new init system format)
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: content: ''
              cat > initfs/etc/init.d/${name} << 'INIT_SCRIPT_EOF'
              ${content}
              INIT_SCRIPT_EOF
            '') (lib.filterAttrs (_: content: content != "") initScriptFiles)
          )}

          # Ion shell configuration
          echo 'let PROMPT = "ion> "' > initfs/etc/ion/initrc

          redox-initfs-ar initfs ${pkgs.bootstrap}/bin/bootstrap -o initfs.img
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          mkdir -p $out/boot
          cp initfs.img $out/boot/initfs
          runHook postInstall
        '';
      };

      # Composable partition images (buildable/inspectable independently)
      kernel = inputs.boot.kernel;
      bootloader = inputs.boot.bootloader;
      diskSizeMB = inputs.boot.diskSizeMB or 512;
      espSizeMB = inputs.boot.espSizeMB or 200;

      espImage = mkEspImage {
        inherit bootloader kernel initfs;
        sizeMB = espSizeMB;
      };

      redoxfsImage = mkRedoxfsImage {
        redoxfs = pkgs.redoxfs;
        inherit rootTree kernel initfs;
        sizeMB = diskSizeMB - espSizeMB - 4; # 4MB for GPT headers
      };

      diskImage = mkDiskImage {
        inherit
          espImage
          redoxfsImage
          bootloader
          kernel
          initfs
          ;
        totalSizeMB = diskSizeMB;
        inherit espSizeMB;
      };

      # System identity — inspired by NixBSD's system.build.toplevel
      # A single store path that ties all system components together
      # and provides metadata for inspection and validation.
      systemName = "redox";
      toplevel = hostPkgs.runCommand "redox-toplevel-${systemName}" { } ''
        mkdir -p $out/nix-support

        # Core system components
        ln -s ${rootTree} $out/root-tree
        ln -s ${initfs} $out/initfs
        ln -s ${kernel}/boot/kernel $out/kernel
        ln -s ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI $out/bootloader
        ln -s ${diskImage} $out/disk-image

        # Configuration access (for inspection)
        ln -s ${rootTree}/etc $out/etc

        # System metadata
        echo -n "x86_64-unknown-redox" > $out/system
        echo -n "${systemName}" > $out/name

        # Record what profile/options produced this system
        echo "rootTree: ${rootTree}" >> $out/nix-support/build-info
        echo "initfs: ${initfs}" >> $out/nix-support/build-info
        echo "kernel: ${kernel}" >> $out/nix-support/build-info
        echo "bootloader: ${bootloader}" >> $out/nix-support/build-info
        echo "diskImage: ${diskImage}" >> $out/nix-support/build-info
      '';

    in
    {
      inherit
        rootTree
        initfs
        diskImage
        toplevel
        espImage
        redoxfsImage
        ;
    };
}
