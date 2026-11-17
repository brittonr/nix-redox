# Offline Orbital variant. 1024x768 is an EDID request, not an arbitrary guest
# resize API; graphical-smoke.py asserts and records the actual firmware mode.
{ pkgs, lib }:
let
  serial = import ./browser-demo.nix { inherit pkgs lib; };
  fixtures = ../fixtures/browser-demo;
  graphicalConfig = name: lib.replaceStrings
    [ "graphics = { enable = false;" ]
    [ "graphics = { enable = true;" ]
    (builtins.readFile (fixtures + "/${name}"));
  before = graphicalConfig "before.nix";
  graphicalCommon = lib.replaceStrings
    [ "!m.configuration.graphics.enabled" ]
    [ "m.configuration.graphics.enabled" ]
    (builtins.readFile (fixtures + "/common.sh"));
  # Force these real packages even though the shared graphics package collector
  # tolerates missing optional desktop packages for other profiles.
  desktopPackages = [ pkgs.orbital pkgs.orbdata pkgs.orbterm pkgs.orbutils ];
  user = uid: home: {
    inherit uid home;
    gid = uid;
    shell = "/nix/system/profile/bin/bash";
    password = "redox";
    createHome = true;
  };
in
serial // {
  "/boot" = serial."/boot" // {
    diskSizeMB = 1024;
    # Default ESP: this initfs may grow to 128 MiB, beyond the serial 64 MiB ESP.
    espSizeMB = 200;
    initfsSizeMB = 128;
    initfsEnableGraphics = true;
  };
  "/environment" = serial."/environment" // {
    systemPackages = serial."/environment".systemPackages ++ desktopPackages;
    etc = serial."/environment".etc // {
      "etc/browser-demo/before.nix".text = before;
      "etc/browser-demo/after.nix".text = graphicalConfig "after.nix";
      "etc/browser-demo/common.sh" = { text = graphicalCommon; mode = "0755"; };
      "etc/redox-system/configuration.nix".text = before;
      "etc/browser-demo/graphical.bashrc".text = ''
        # This runs in the authenticated Orbterm child, never the serial shell.
        # Initialize readline before advertising readiness: keys submitted while
        # the first interactive shell starts can otherwise be discarded.
        if [[ -n "''${ORBTERM_VERSION:-}" && -t 0 && -t 1 ]]; then
          if bind -v > /dev/null; then
            printf 'REDOX_BROWSER_GRAPHICAL_SHELL_READY:v1:uid=%s\n' "$UID" > /tmp/browser-graphical-shell-ready
          fi
        fi
      '';
    };
  };
  "/graphics" = {
    enable = true;
    resolution = "1024x768";
    loginCommand = "orblogin orbterm /nix/system/profile/bin/bash --rcfile /etc/browser-demo/graphical.bashrc -i";
  };
  "/hardware" = serial."/hardware" // {
    graphicsEnable = true;
    # UEFI GOP -> vesad with standard VGA, not a virtio GPU or USB tablet.
    graphicsDrivers = [ ];
    usbEnable = false;
  };
  "/audio".enable = false;
  "/users".users = {
    root = user 0 "/root";
    user = user 1000 "/home/user";
  };
  "/virtualisation" = serial."/virtualisation" // {
    graphics = true;
    memorySize = 1024;
    qemuExtraArgs = [
      "-nic" "none" "-vga" "std"
      "-global" "VGA.xres=1024" "-global" "VGA.yres=768"
    ];
  };
}
