# Build Module (/build)
#
# Single consolidated build module that produces all build outputs.
# In adios, inputs give module OPTIONS (not impl outputs), so this
# module reads all config and produces rootTree, initfs, diskImage.

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

      # Networking scripts
      netcfgChScript = ''
        #!/bin/ion
        echo "Configuring network for Cloud Hypervisor..."
        if not exists -f /scheme/netcfg/ifaces/eth0/mac
            echo "Error: eth0 not found"
            exit 1
        end
        let ip = $(/bin/cat /etc/net/cloud-hypervisor/ip)
        let gateway = $(/bin/cat /etc/net/cloud-hypervisor/gateway)
        echo "$ip/24" > /scheme/netcfg/ifaces/eth0/addr/set
        echo "default via $gateway" > /scheme/netcfg/route/add
        echo "1.1.1.1" > /scheme/netcfg/resolv/nameserver
        echo "Network configured: $ip/24 via $gateway"
      '';

      netcfgAutoScript = ''
        #!/bin/ion
        let i:int = 0
        while test $i -lt 30
            if exists -f /scheme/netcfg/ifaces/eth0/mac
                break
            end
            let i += 1
        end
        if not exists -f /scheme/netcfg/ifaces/eth0/mac
            echo "netcfg-auto: eth0 not found"
            exit 0
        end
        echo "netcfg-auto: Waiting for DHCP..."
        let has_network = 0
        let check:int = 0
        while test $check -lt 15
            let wait:int = 0
            while test $wait -lt 500000
                let wait += 1
            end
            let ip_content = $(/bin/cat /scheme/netcfg/ifaces/eth0/addr/list 2>/dev/null)
            if not test "$ip_content" = ""
                echo "netcfg-auto: DHCP configured: $ip_content"
                let has_network = 1
                break
            end
            let check += 1
        end
        if test $has_network -eq 0
            if exists -f /etc/net/cloud-hypervisor/ip
                echo "netcfg-auto: No DHCP, applying static..."
                let ip = $(/bin/cat /etc/net/cloud-hypervisor/ip)
                let gateway = $(/bin/cat /etc/net/cloud-hypervisor/gateway)
                echo "$ip/24" > /scheme/netcfg/ifaces/eth0/addr/set
                echo "default via $gateway" > /scheme/netcfg/route/add
                echo "1.1.1.1" > /scheme/netcfg/resolv/nameserver
                echo "netcfg-auto: Static config applied ($ip)"
            else
                echo "netcfg-auto: No static config available"
            end
        end
      '';

      firstIfaceName =
        let
          names = builtins.attrNames (inputs.networking.interfaces or { });
        in
        if names != [ ] then builtins.head names else null;
      firstIface =
        if firstIfaceName != null then inputs.networking.interfaces.${firstIfaceName} else null;

      netcfgStaticScript =
        if firstIface != null then
          ''
            #!/bin/ion
            echo "netcfg-static: Configuring..."
            let i:int = 0
            while test $i -lt 30
                if exists -f /scheme/netcfg/ifaces/eth0/mac
                    break
                end
                let i += 1
            end
            if not exists -f /scheme/netcfg/ifaces/eth0/mac
                echo "netcfg-static: eth0 not found"
                exit 1
            end
            echo "${firstIface.address}/24" > /scheme/netcfg/ifaces/eth0/addr/set
            echo "default via ${firstIface.gateway}" > /scheme/netcfg/route/add
            echo "1.1.1.1" > /scheme/netcfg/resolv/nameserver
            echo "netcfg-static: Network ready (${firstIface.address})"
            /bin/ping -c 1 ${firstIface.gateway}
          ''
        else
          ''
            #!/bin/ion
            echo "netcfg-static: No interfaces configured"
          '';

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
              text = "echo \"Running network auto-configuration...\"\nnowait /bin/netcfg-auto-quiet";
              directory = "init.d";
            };
          })
          // (lib.optionalAttrs (inputs.networking.mode == "static" && inputs.networking.interfaces != { }) {
            "15_netcfg" = {
              text = "/bin/netcfg-static";
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
        "bin/netcfg-ch" = {
          text = netcfgChScript;
          mode = "0755";
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
      // (lib.optionalAttrs (networkingEnabled && inputs.networking.mode == "auto") {
        "bin/netcfg-auto" = {
          text = netcfgAutoScript;
          mode = "0755";
        };
        "bin/netcfg-auto-quiet" = {
          text = "#!/bin/ion\n/bin/netcfg-auto > /var/log/netcfg.log";
          mode = "0755";
        };
      })
      // (lib.optionalAttrs (networkingEnabled && inputs.networking.mode == "static") {
        "bin/netcfg-static" = {
          text = netcfgStaticScript;
          mode = "0755";
        };
      })
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
      # Init script files
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
        ) allInitScripts
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

      diskImage =
        let
          kernel = inputs.boot.kernel;
          bootloader = inputs.boot.bootloader;
          diskSizeMB = inputs.boot.diskSizeMB or 512;
          espSizeMB = inputs.boot.espSizeMB or 200;
        in
        hostPkgs.stdenv.mkDerivation {
          pname = "redox-disk-image";
          version = "unstable";
          dontUnpack = true;
          dontPatchELF = true;
          dontFixup = true;
          nativeBuildInputs = with hostPkgs; [
            parted
            mtools
            dosfstools
            pkgs.redoxfs
          ];
          SOURCE_DATE_EPOCH = "1";
          buildPhase = ''
            runHook preBuild
            IMAGE_SIZE=$((${toString diskSizeMB} * 1024 * 1024))
            ESP_SIZE=$((${toString espSizeMB} * 1024 * 1024))
            ESP_SECTORS=$((ESP_SIZE / 512))
            REDOXFS_START=$((2048 + ESP_SECTORS))
            REDOXFS_END=$(($(($IMAGE_SIZE / 512)) - 34))
            REDOXFS_SECTORS=$((REDOXFS_END - REDOXFS_START))
            REDOXFS_SIZE=$((REDOXFS_SECTORS * 512))

            truncate -s $IMAGE_SIZE disk.img
            parted -s disk.img mklabel gpt
            parted -s disk.img mkpart ESP fat32 1MiB ${toString (espSizeMB + 1)}MiB
            parted -s disk.img set 1 boot on
            parted -s disk.img set 1 esp on
            parted -s disk.img mkpart RedoxFS ${toString (espSizeMB + 1)}MiB 100%

            truncate -s $ESP_SIZE esp.img
            mkfs.vfat -F 32 -n "EFI" esp.img
            mmd -i esp.img ::EFI ::EFI/BOOT
            mcopy -i esp.img ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI ::EFI/BOOT/
            mcopy -i esp.img ${kernel}/boot/kernel ::EFI/BOOT/kernel
            mcopy -i esp.img ${initfs}/boot/initfs ::EFI/BOOT/initfs
            echo '\EFI\BOOT\BOOTX64.EFI' > startup.nsh
            mcopy -i esp.img startup.nsh ::
            dd if=esp.img of=disk.img bs=512 seek=2048 conv=notrunc

            mkdir -p redoxfs-root
            cp -r ${rootTree}/* redoxfs-root/
            mkdir -p redoxfs-root/boot
            cp ${kernel}/boot/kernel redoxfs-root/boot/kernel
            cp ${initfs}/boot/initfs redoxfs-root/boot/initfs

            truncate -s $REDOXFS_SIZE redoxfs.img
            redoxfs-ar --uid 0 --gid 0 redoxfs.img redoxfs-root
            dd if=redoxfs.img of=disk.img bs=512 seek=$REDOXFS_START conv=notrunc
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out $out/boot
            cp disk.img $out/redox.img
            cp ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI $out/boot/
            cp ${kernel}/boot/kernel $out/boot/
            cp ${initfs}/boot/initfs $out/boot/
            runHook postInstall
          '';
        };

    in
    {
      inherit rootTree initfs diskImage;
    };
}
