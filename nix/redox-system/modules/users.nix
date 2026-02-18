# Users Configuration (/users)
#
# User accounts and groups.
# The /build module generates /etc/passwd, /etc/group, /etc/shadow
# and creates home directories from these options.

adios:

let
  t = adios.types;

  userType = t.struct "User" {
    uid = t.int;
    gid = t.int;
    home = t.string;
    shell = t.string;
    password = t.string;
    realname = t.optionalAttr t.string;
    createHome = t.optionalAttr t.bool;
  };

  groupType = t.struct "Group" {
    gid = t.int;
    members = t.listOf t.string;
  };
in

{
  name = "users";

  options = {
    users = {
      type = t.attrsOf userType;
      default = {
        root = {
          uid = 0;
          gid = 0;
          home = "/root";
          shell = "/bin/ion";
          password = "";
          realname = "root";
          createHome = true;
        };
        user = {
          uid = 1000;
          gid = 1000;
          home = "/home/user";
          shell = "/bin/ion";
          password = "";
          realname = "Default User";
          createHome = true;
        };
      };
      description = "System user accounts";
    };

    groups = {
      type = t.attrsOf groupType;
      default = {
        root = {
          gid = 0;
          members = [ ];
        };
        user = {
          gid = 1000;
          members = [ "user" ];
        };
      };
      description = "System groups";
    };
  };

  impl = { options }: options;
}
