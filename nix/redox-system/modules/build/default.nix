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
    security = {
      path = "/security";
    };
    time = {
      path = "/time";
    };
    programs = {
      path = "/programs";
    };
    logging = {
      path = "/logging";
    };
    power = {
      path = "/power";
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

      # ===== NEW MODULE OPTIONS =====

      # /time
      hostname = inputs.time.hostname or "redox";
      timezone = inputs.time.timezone or "UTC";
      ntpEnabled = inputs.time.ntpEnable or false;
      ntpServers = inputs.time.ntpServers or [ "pool.ntp.org" ];
      hwclock = inputs.time.hwclock or "utc";

      # /logging
      logLevel = inputs.logging.level or "info";
      kernelLogLevel = inputs.logging.kernelLogLevel or "warn";
      logToFile = inputs.logging.logToFile or true;
      logPath = inputs.logging.logPath or "/var/log";

      # /security
      protectKernelSchemes = inputs.security.protectKernelSchemes or true;
      requirePasswords = inputs.security.requirePasswords or false;
      allowRemoteRoot = inputs.security.allowRemoteRoot or false;
      setuidPrograms =
        inputs.security.setuidPrograms or [
          "su"
          "sudo"
          "login"
          "passwd"
        ];

      # /programs
      ionConfig =
        inputs.programs.ion or {
          enable = true;
          prompt = "\\$USER@\\$HOSTNAME \\$PWD# ";
          initExtra = "";
        };
      helixConfig =
        inputs.programs.helix or {
          enable = false;
          theme = "default";
        };
      defaultEditor = inputs.programs.editor or "/bin/sodium";
      httpdConfig =
        inputs.programs.httpd or {
          enable = false;
          port = 8080;
          rootDir = "/var/www";
        };

      # /power
      acpiEnabled = inputs.power.acpiEnable or true;
      powerAction = inputs.power.powerAction or "shutdown";
      rebootOnPanic = inputs.power.rebootOnPanic or false;

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
        ++ (lib.optional networkingEnabled "/var/log")
        ++ (lib.optional logToFile logPath)
        ++ [ "/etc/security" ]
        ++ (lib.optional acpiEnabled "/etc/acpi")
        ++ (lib.optional (helixConfig.enable or false) "/etc/helix")
        ++ (lib.optional (httpdConfig.enable or false) (httpdConfig.rootDir or "/var/www"));

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

      # ===== ASSERTIONS (cross-module validation) =====
      # Inspired by nix-darwin's assertions system.
      # Checks invariants across modules that Korora types alone can't express.
      assertions = [
        {
          assertion = !graphicsEnabled || (pkgs ? orbital);
          message = "graphics.enable requires the 'orbital' package. Add it to pkgs or disable graphics.";
        }
        {
          assertion =
            !(networkingEnabled && (inputs.networking.mode or "auto") == "static")
            || (inputs.networking.interfaces or { } != { });
          message = "networking.mode = 'static' requires at least one interface in networking.interfaces.";
        }
        {
          assertion =
            !graphicsEnabled
            || builtins.any (d: d == "virtio-gpud" || d == "bgad") (inputs.hardware.graphicsDrivers or [ ]);
          message = "graphics.enable is set but no graphics drivers configured in hardware.graphicsDrivers.";
        }
        {
          assertion = diskSizeMB > espSizeMB;
          message = "boot.diskSizeMB (${toString diskSizeMB}) must be greater than boot.espSizeMB (${toString espSizeMB}).";
        }
        {
          assertion = diskSizeMB - espSizeMB >= 16;
          message = "RedoxFS partition must be at least 16MB. Increase diskSizeMB or decrease espSizeMB.";
        }
        {
          assertion = builtins.all (user: (user.uid or 0) >= 0) (lib.attrValues (inputs.users.users or { }));
          message = "All user UIDs must be non-negative.";
        }
        # New module assertions
        {
          assertion = !(ntpEnabled && !networkingEnabled);
          message = "time.ntpEnable requires networking.enable = true.";
        }
        {
          assertion =
            !requirePasswords
            || builtins.all (user: (user.uid or 0) == 0 || (user.password or "") != "") (
              lib.attrValues (inputs.users.users or { })
            );
          message = "security.requirePasswords is set but some non-root users have empty passwords.";
        }
        {
          assertion = (inputs.logging.maxLogSizeMB or 10) > 0;
          message = "logging.maxLogSizeMB must be positive.";
        }
        {
          assertion = (inputs.power.idleTimeoutMinutes or 30) > 0;
          message = "power.idleTimeoutMinutes must be positive.";
        }
      ];

      # Warnings: non-fatal notices traced during evaluation
      warnings = builtins.filter (w: w != "") [
        (lib.optionalString (graphicsEnabled && !audioEnabled)
          "Graphics is enabled but audio is not. Consider setting hardware.audioEnable = true for a complete desktop experience."
        )
        (lib.optionalString (diskSizeMB < 256) "Disk size is less than 256MB. Some packages may not fit.")
        (lib.optionalString (
          ntpEnabled && (inputs.time.ntpServers or [ ]) == [ ]
        ) "NTP is enabled but no NTP servers configured.")
        (lib.optionalString (
          !protectKernelSchemes
        ) "Kernel scheme protection is disabled. This may expose system internals to userspace.")
        (lib.optionalString (
          allowRemoteRoot && networkingEnabled
        ) "Remote root login is allowed with networking enabled. Consider disabling for production.")
      ];

      # Process assertions — throw at eval time if any fail
      failedAssertions = builtins.filter (a: !a.assertion) assertions;
      assertionCheck =
        if failedAssertions != [ ] then
          throw "\nFailed assertions:\n${
            lib.concatStringsSep "\n" (map (a: "- ${a.message}") failedAssertions)
          }"
        else
          true;

      # Process warnings — trace non-empty ones
      warningCheck = lib.foldr (w: x: builtins.trace "warning: ${w}" x) true warnings;

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
        export HOSTNAME ${hostname}
        export TZ ${timezone}
        export EDITOR ${defaultEditor}
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
      # ===== NEW MODULE GENERATED FILES =====

      # /time: hostname, timezone
      // {
        "etc/hostname" = {
          text = hostname;
          mode = "0644";
        };
        "etc/timezone" = {
          text = timezone;
          mode = "0644";
        };
        "etc/hwclock" = {
          text = hwclock;
          mode = "0644";
        };
      }
      // (lib.optionalAttrs ntpEnabled {
        "etc/ntp.conf" = {
          text =
            "# NTP configuration (generated by adios module system)\n"
            + lib.concatMapStringsSep "\n" (server: "server ${server}") ntpServers
            + "\n";
          mode = "0644";
        };
      })

      # /logging: log config
      // (lib.optionalAttrs logToFile {
        "etc/logging.conf" = {
          text = lib.concatStringsSep "\n" [
            "# RedoxOS Logging Configuration (generated by adios module system)"
            "level=${logLevel}"
            "kernel_level=${kernelLogLevel}"
            "log_path=${logPath}"
            "max_size_mb=${toString (inputs.logging.maxLogSizeMB or 10)}"
            "persist=${if inputs.logging.persistAcrossBoot or false then "true" else "false"}"
          ];
          mode = "0644";
        };
      })

      # /security: namespace access, security policy
      // {
        "etc/security/namespaces" = {
          text =
            "# Scheme namespace access policy (generated by adios module system)\n"
            + lib.concatStringsSep "\n" (
              lib.mapAttrsToList (scheme: access: "${scheme}=${access}") (inputs.security.namespaceAccess or { })
            )
            + "\n";
          mode = "0644";
        };
        "etc/security/policy" = {
          text = lib.concatStringsSep "\n" [
            "# Security policy (generated by adios module system)"
            "protect_kernel_schemes=${if protectKernelSchemes then "true" else "false"}"
            "require_passwords=${if requirePasswords then "true" else "false"}"
            "allow_remote_root=${if allowRemoteRoot then "true" else "false"}"
          ];
          mode = "0644";
        };
        "etc/security/setuid" = {
          text =
            "# Setuid programs (generated by adios module system)\n"
            + lib.concatStringsSep "\n" setuidPrograms
            + "\n";
          mode = "0644";
        };
      }

      # /programs: ion initrc, helix config, editor
      // {
        "etc/ion/initrc" = {
          text =
            let
              ion = ionConfig;
            in
            lib.concatStringsSep "\n" (
              [ ''let PROMPT = "${ion.prompt or "ion> "}"'' ]
              ++ [ "export EDITOR ${defaultEditor}" ]
              ++ lib.optional (ion.initExtra or "" != "") (ion.initExtra)
            );
          mode = "0644";
        };
      }
      // (lib.optionalAttrs (helixConfig.enable or false) {
        "etc/helix/config.toml" = {
          text = ''
            # Helix editor config (generated by adios module system)
            theme = "${helixConfig.theme or "default"}"
          '';
          mode = "0644";
        };
      })
      // (lib.optionalAttrs (httpdConfig.enable or false) {
        "etc/httpd.conf" = {
          text = lib.concatStringsSep "\n" [
            "# HTTP server config (generated by adios module system)"
            "port=${toString (httpdConfig.port or 8080)}"
            "root_dir=${httpdConfig.rootDir or "/var/www"}"
          ];
          mode = "0644";
        };
      })

      # /power: ACPI config
      // (lib.optionalAttrs acpiEnabled {
        "etc/acpi/config" = {
          text = lib.concatStringsSep "\n" [
            "# ACPI power management (generated by adios module system)"
            "power_action=${powerAction}"
            "idle_action=${inputs.power.idleAction or "none"}"
            "idle_timeout_minutes=${toString (inputs.power.idleTimeoutMinutes or 30)}"
            "reboot_on_panic=${if rebootOnPanic then "true" else "false"}"
          ];
          mode = "0644";
        };
      })

      # System manifest (base — file hashes merged at rootTree build time)
      // {
        "etc/redox-system/manifest.json" = {
          source = manifestJson;
          mode = "0644";
        };
      }

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

      rootTree =
        assert assertionCheck;
        assert warningCheck;
        hostPkgs.runCommand "redox-root-tree"
          {
            nativeBuildInputs = [ hostPkgs.python3 ];
          }
          ''
            ${mkDirs allDirectories}
            mkdir -p $out/dev
            ${mkDevSymlinks}
            ${mkSpecialSymlinks}
            ${mkPackages}
            ${mkGeneratedFiles}

            # Compute file hashes, generation buildHash, and seed generations dir.
            # The base manifest was written above; now we add:
            #   1. "files" key with SHA256 hashes of every rootTree file
            #   2. "generation.buildHash" — SHA256 of the sorted file inventory
            #   3. /etc/redox-system/generations/1/ with a copy of the manifest
            python3 - <<'HASH_SCRIPT'
            import hashlib, json, os, stat

            root = os.environ["out"]
            manifest_rel = "etc/redox-system/manifest.json"
            manifest_path = os.path.join(root, manifest_rel)
            gen_dir = os.path.join(root, "etc/redox-system/generations/1")

            # Read base manifest
            with open(manifest_path) as f:
                manifest = json.load(f)

            # Walk tree and compute SHA256 hashes
            inventory = {}
            for dirpath, dirs, files in os.walk(root):
                dirs.sort()
                for name in sorted(files):
                    path = os.path.join(dirpath, name)
                    relpath = os.path.relpath(path, root)

                    # Skip the manifest itself (self-referential)
                    if relpath == manifest_rel:
                        continue

                    # Skip generation copies (they're copies of this manifest)
                    if relpath.startswith("etc/redox-system/generations/"):
                        continue

                    # Skip symlinks — they point outside the tree
                    if os.path.islink(path):
                        continue

                    st = os.stat(path)
                    with open(path, "rb") as f:
                        h = hashlib.sha256(f.read()).hexdigest()

                    inventory[relpath] = {
                        "sha256": h,
                        "size": st.st_size,
                        "mode": oct(stat.S_IMODE(st.st_mode))[2:],
                    }

            # Compute buildHash from the sorted file inventory
            # This is a content-addressable fingerprint of the entire rootTree
            inventory_json = json.dumps(inventory, sort_keys=True)
            build_hash = hashlib.sha256(inventory_json.encode()).hexdigest()

            # Merge file inventory and buildHash into manifest
            manifest["files"] = inventory
            manifest["generation"]["buildHash"] = build_hash

            # Write final manifest
            with open(manifest_path, "w") as f:
                json.dump(manifest, f, indent=2, sort_keys=True)

            # Seed generation 1 — copy manifest to generations directory
            os.makedirs(gen_dir, exist_ok=True)
            with open(os.path.join(gen_dir, "manifest.json"), "w") as f:
                json.dump(manifest, f, indent=2, sort_keys=True)

            HASH_SCRIPT

            echo "Root tree: $(find $out -type f | wc -l) files, $(find $out/bin -type f 2>/dev/null | wc -l) binaries"
            echo "Manifest: $(python3 -c "import json; m=json.load(open('$out/etc/redox-system/manifest.json')); print(len(m.get('files',{})),'tracked files')")"
          '';

      # ===== SYSTEM CHECKS (build-time rootTree validation) =====
      # Inspired by nix-darwin's system.checks module.
      # Validates that built artifacts contain everything needed for boot.
      systemChecks = hostPkgs.runCommand "redox-system-checks" { } ''
        set -euo pipefail
        echo "Running system checks on rootTree..."

        # Check 1: Essential files exist
        for f in etc/passwd etc/group etc/shadow etc/init.toml startup.sh; do
          if [ ! -e "${rootTree}/$f" ]; then
            echo "FAIL: Missing essential file: $f"
            exit 1
          fi
        done
        echo "  ✓ Essential files present"

        # Check 2: passwd has at least one entry
        if [ ! -s "${rootTree}/etc/passwd" ]; then
          echo "FAIL: /etc/passwd is empty — no users defined"
          exit 1
        fi
        echo "  ✓ passwd has entries"

        # Check 3: passwd uses semicolon delimiter (Redox format)
        if ! grep -q ';' "${rootTree}/etc/passwd"; then
          echo "FAIL: /etc/passwd not in Redox format (semicolon-delimited)"
          echo "  Contents: $(head -1 ${rootTree}/etc/passwd)"
          exit 1
        fi
        echo "  ✓ passwd format correct"

        # Check 4: If networking enabled, verify net config exists
        ${lib.optionalString networkingEnabled ''
          if [ ! -d "${rootTree}/etc/net" ]; then
            echo "FAIL: Networking enabled but /etc/net directory missing"
            exit 1
          fi
          if [ ! -e "${rootTree}/etc/net/dns" ]; then
            echo "FAIL: Networking enabled but /etc/net/dns missing"
            exit 1
          fi
          echo "  ✓ Network configuration present"
        ''}

        # Check 5: If graphics enabled, verify profile has orbital config
        ${lib.optionalString graphicsEnabled ''
          if ! grep -q 'ORBITAL_RESOLUTION' "${rootTree}/etc/profile" 2>/dev/null; then
            echo "WARN: Graphics enabled but ORBITAL_RESOLUTION not in profile"
          fi
          echo "  ✓ Graphics configuration present"
        ''}

        # Check 6: Hostname file exists
        if [ ! -e "${rootTree}/etc/hostname" ]; then
          echo "FAIL: Missing /etc/hostname"
          exit 1
        fi
        echo "  ✓ hostname present ($(cat ${rootTree}/etc/hostname))"

        # Check 7: Security policy exists
        if [ ! -e "${rootTree}/etc/security/policy" ]; then
          echo "FAIL: Missing /etc/security/policy"
          exit 1
        fi
        echo "  ✓ security policy present"

        # Check 9: Init scripts directory should have content
        if [ -d "${rootTree}/etc/init.d" ]; then
          count=$(find "${rootTree}/etc/init.d" -type f | wc -l)
          echo "  ✓ Init scripts present ($count scripts)"
        fi

        # Check 10: startup.sh should be executable (Nix adjusts to 555)
        if [ -e "${rootTree}/startup.sh" ]; then
          mode=$(stat -c '%a' "${rootTree}/startup.sh")
          if [ "$mode" != "555" ]; then
            echo "WARN: startup.sh has mode $mode (expected 555)"
          fi
          echo "  ✓ startup.sh executable"
        fi

        echo ""
        echo "All system checks passed."
        touch $out
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

      # ===== VERSION TRACKING =====
      # Inspired by nix-darwin's system/version.nix.
      # Structured metadata embedded in the system for inspection.
      systemName = "redox";
      versionInfo = {
        redoxSystemVersion = "0.5.0";
        target = "x86_64-unknown-redox";
        profile = systemName;
        inherit hostname timezone;
        graphicsEnabled = graphicsEnabled;
        networkingEnabled = networkingEnabled;
        networkMode = inputs.networking.mode or "auto";
        ntpEnabled = ntpEnabled;
        inherit logLevel;
        acpiEnabled = acpiEnabled;
        inherit protectKernelSchemes;
        diskSizeMB = diskSizeMB;
        espSizeMB = espSizeMB;
        userCount = builtins.length (builtins.attrNames (inputs.users.users or { }));
        packageCount = builtins.length allPackages;
        driverCount = builtins.length allDrivers;
      };

      versionJson = hostPkgs.writeText "redox-version.json" (builtins.toJSON versionInfo);

      # ===== SYSTEM MANIFEST =====
      # Embedded at /etc/redox-system/manifest.json in rootTree.
      # Provides live system introspection via `snix system info/verify/diff`.
      # File hashes are computed post-build (see rootTree derivation).
      manifestData = {
        manifestVersion = 1; # Schema version for forward compatibility

        system = {
          inherit (versionInfo) redoxSystemVersion target;
          inherit hostname timezone;
          profile = systemName;
        };

        # Generation tracking — seeded at build time, managed by `snix system switch`
        generation = {
          id = 1; # First build is generation 1
          buildHash = ""; # Populated at rootTree build time (content hash)
          description = "initial build";
          timestamp = ""; # Set at switch/activation time (not build, for reproducibility)
        };

        configuration = {
          boot = {
            inherit diskSizeMB espSizeMB;
          };
          hardware = {
            storageDrivers = inputs.hardware.storageDrivers or [ ];
            networkDrivers = inputs.hardware.networkDrivers or [ ];
            graphicsDrivers = lib.optionals graphicsEnabled (inputs.hardware.graphicsDrivers or [ ]);
            audioDrivers = lib.optionals audioEnabled (inputs.hardware.audioDrivers or [ ]);
            inherit usbEnabled;
          };
          networking = {
            enabled = networkingEnabled;
            mode = inputs.networking.mode or "auto";
            dns = inputs.networking.dns or [ ];
          };
          graphics = {
            enabled = graphicsEnabled;
            resolution = inputs.graphics.resolution or "1024x768";
          };
          security = {
            inherit protectKernelSchemes requirePasswords allowRemoteRoot;
          };
          logging = {
            inherit logLevel kernelLogLevel logToFile;
            maxLogSizeMB = inputs.logging.maxLogSizeMB or 10;
          };
          power = {
            inherit acpiEnabled powerAction rebootOnPanic;
          };
        };

        packages = builtins.map (pkg: {
          name = pkg.pname or (builtins.parseDrvName pkg.name).name;
          version = pkg.version or (builtins.parseDrvName pkg.name).version;
        }) allPackages;

        drivers = {
          all = allDrivers;
          initfs = initfsDaemons;
          core = coreDaemons;
        };

        users = builtins.mapAttrs (name: user: {
          uid = user.uid;
          gid = user.gid;
          home = user.home;
          shell = user.shell;
        }) (inputs.users.users or { });

        groups = builtins.mapAttrs (name: group: {
          gid = group.gid;
          members = group.members or [ ];
        }) (inputs.users.groups or { });

        services = {
          initScripts = builtins.attrNames allInitScriptsWithServices;
          startupScript = "/startup.sh";
        };

        # File hashes are computed at build time and merged into this manifest.
        # The key "files" is populated by the rootTree derivation (see below).
        # This avoids a circular dependency: manifest.json is written first,
        # then file hashes are computed and merged in.
      };

      manifestJson = hostPkgs.writeText "redox-manifest-base.json" (builtins.toJSON manifestData);

      # System identity — inspired by NixBSD's system.build.toplevel
      # A single store path that ties all system components together
      # and provides metadata for inspection and validation.
      toplevel =
        hostPkgs.runCommand "redox-toplevel-${systemName}"
          {
            inherit systemChecks; # Force checks to run
          }
          ''
            mkdir -p $out/nix-support

            # Core system components
            ln -s ${rootTree} $out/root-tree
            ln -s ${initfs} $out/initfs
            ln -s ${kernel}/boot/kernel $out/kernel
            ln -s ${bootloader}/boot/EFI/BOOT/BOOTX64.EFI $out/bootloader
            ln -s ${diskImage} $out/disk-image

            # Validation
            ln -s ${systemChecks} $out/checks

            # Configuration access (for inspection)
            ln -s ${rootTree}/etc $out/etc

            # System metadata
            echo -n "x86_64-unknown-redox" > $out/system
            echo -n "${systemName}" > $out/name
            ln -s ${versionJson} $out/version.json

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
        systemChecks
        ;
      version = versionInfo;

      # VM configuration for runner scripts (from /virtualisation module)
      vmConfig = {
        vmm = inputs.virtualisation.vmm or "cloud-hypervisor";
        memorySize = inputs.virtualisation.memorySize or 2048;
        cpus = inputs.virtualisation.cpus or 4;
        graphics = inputs.virtualisation.graphics or false;
        serialConsole = inputs.virtualisation.serialConsole or true;
        hugepages = inputs.virtualisation.hugepages or false;
        directIO = inputs.virtualisation.directIO or true;
        apiSocket = inputs.virtualisation.apiSocket or false;
        tapNetworking = inputs.virtualisation.tapNetworking or false;
        qemuExtraArgs = inputs.virtualisation.qemuExtraArgs or [ ];
      };
    };
}
