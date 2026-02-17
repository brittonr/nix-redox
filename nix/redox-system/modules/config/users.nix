# RedoxOS User and Group Configuration
#
# Manages system users and groups, generating:
#   - /etc/passwd - User account database
#   - /etc/group - Group database
#   - /etc/shadow - Password shadow file (stub, actual passwords in passwd)
#   - Home directory structure
#
# Redox uses semicolon-delimited format (not colon like Unix):
#   passwd: name;password;uid;gid;realname;home;shell
#   group: name;x;gid;members

{
  config,
  lib,
  pkgs,
  hostPkgs,
  redoxSystemLib,
  ...
}:

let
  inherit (lib)
    mkOption
    mkDefault
    mkIf
    mkMerge
    types
    mapAttrsToList
    concatStringsSep
    ;

  cfg = config.redox.users;

  # User account submodule
  userOpts =
    { name, ... }:
    {
      options = {
        uid = mkOption {
          type = types.int;
          description = "User ID";
        };

        gid = mkOption {
          type = types.int;
          description = "Primary group ID";
        };

        home = mkOption {
          type = types.str;
          default = "/home/${name}";
          description = "Home directory path";
        };

        shell = mkOption {
          type = types.str;
          default = "/bin/ion";
          description = "Login shell";
        };

        password = mkOption {
          type = types.str;
          default = "";
          description = ''
            Password field. Empty = no password, "!" = locked account.
            In production, use proper password hashing.
          '';
        };

        createHome = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to create the home directory";
        };

        realname = mkOption {
          type = types.str;
          default = name;
          description = "Real name / GECOS field";
        };
      };
    };

  # Group submodule
  groupOpts =
    { name, ... }:
    {
      options = {
        gid = mkOption {
          type = types.int;
          description = "Group ID";
        };

        members = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "List of usernames in this group";
        };
      };
    };

  # Generate /etc/passwd content
  passwdContent =
    concatStringsSep "\n" (
      mapAttrsToList (
        name: user:
        redoxSystemLib.mkPasswdEntry {
          inherit name;
          inherit (user)
            uid
            gid
            home
            shell
            password
            ;
          realname = user.realname;
        }
      ) cfg.users
    )
    + "\n";

  # Generate /etc/group content
  groupContent =
    concatStringsSep "\n" (
      mapAttrsToList (
        name: group:
        redoxSystemLib.mkGroupEntry {
          inherit name;
          inherit (group) gid members;
        }
      ) cfg.groups
    )
    + "\n";

  # Generate /etc/shadow content (stub - Redox doesn't use shadow, but we create it for compatibility)
  shadowContent = concatStringsSep "\n" (mapAttrsToList (name: user: "${name};") cfg.users) + "\n";

  # Collect home directories that need to be created
  homeDirs = mapAttrsToList (name: user: if user.createHome then user.home else null) cfg.users;

in
{
  options.redox.users = {
    users = mkOption {
      type = types.attrsOf (types.submodule userOpts);
      default = { };
      description = "System user accounts";
    };

    groups = mkOption {
      type = types.attrsOf (types.submodule groupOpts);
      default = { };
      description = "System groups";
    };
  };

  config = {
    # Default users and groups
    redox.users.users = {
      root = mkDefault {
        uid = 0;
        gid = 0;
        home = "/root";
        shell = "/bin/ion";
        password = "";
        realname = "root";
      };

      user = mkDefault {
        uid = 1000;
        gid = 1000;
        home = "/home/user";
        shell = "/bin/ion";
        password = "";
        realname = "Default User";
      };
    };

    redox.users.groups = {
      root = mkDefault {
        gid = 0;
        members = [ ];
      };

      user = mkDefault {
        gid = 1000;
        members = [ "user" ];
      };
    };

    # Generate system files
    redox.generatedFiles = {
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
    };

    # Create home directories
    redox.filesystem.extraDirectories = lib.filter (dir: dir != null) homeDirs;
  };
}
