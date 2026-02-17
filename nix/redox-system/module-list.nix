# RedoxOS Base Module List
#
# This file lists all base modules that form the foundation of the RedoxOS module system.
# Modules are organized by category:
#
# 1. config/* - Configuration modules (declarative options for system settings)
#    - boot.nix: Bootloader and kernel configuration
#    - environment.nix: Environment variables, PATH, packages
#    - filesystem.nix: Filesystem layout, partitions (disko-inspired)
#    - graphics.nix: Orbital display server and graphics
#    - hardware.nix: Hardware drivers, PCI device configuration (pcid)
#    - networking.nix: Network configuration, DHCP, static IP
#    - services.nix: System services, init.rc generation
#    - users.nix: User and group management
#
# 2. system/* - System-level modules (cross-cutting concerns)
#    - activation.nix: System activation scripts, setup logic
#
# 3. build/* - Build output modules (derivations for final artifacts)
#    - initfs.nix: Initial RAM filesystem generation
#    - disk-image.nix: Bootable disk image creation
#    - toplevel.nix: Combined system toplevel (like NixOS system.build.toplevel)
#
# Module evaluation order:
#   - All modules are evaluated together by lib.evalModules
#   - Order in this list doesn't matter (dependencies are explicit via config references)
#   - Each module can declare options and provide config values
#
# Adding new modules:
#   1. Create the module file in the appropriate directory
#   2. Add the path to this list
#   3. Module will be automatically evaluated with all others

[
  # Configuration modules - declare options and defaults
  ./modules/config/boot.nix
  ./modules/config/environment.nix
  ./modules/config/filesystem.nix
  ./modules/config/graphics.nix
  ./modules/config/hardware.nix
  ./modules/config/networking.nix
  ./modules/config/services.nix
  ./modules/config/users.nix

  # System modules - activation and setup
  ./modules/system/activation.nix

  # Build modules - generate final artifacts
  ./modules/build/initfs.nix
  ./modules/build/disk-image.nix
  ./modules/build/toplevel.nix
]
