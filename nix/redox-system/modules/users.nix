# Users Configuration (/users)
#
# User accounts and groups.
# The /build module generates /etc/passwd, /etc/group, /etc/shadow
# and creates home directories from these options.

adios:

{
  name = "users";

  options = {
    users = {
      type = adios.types.attrs;
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
      type = adios.types.attrs;
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
