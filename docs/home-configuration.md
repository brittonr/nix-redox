# Home configuration

`nix-redox` uses an adios-native, **data-only** home layer. Files declared for a
user are baked into the image; there is no Home Manager runtime, Nix store
requirement, or activation phase.

```nix
"/users".users.admin = {
  uid = 1001;
  gid = 1001;
  home = "/home/admin";
  shell = "/bin/ion";
  password = "redox";
  realname = "Admin";
  createHome = true;

  files = {
    ".config/redox/welcome.txt" = {
      text = "Managed as declarative home data.\n";
      mode = "0644";
    };
    ".config/app/settings.toml" = {
      text = "enabled = true\n";
    };
  };
};
```

Paths are relative to the user's home. `mode` defaults to `0644`. The files are
created in the root tree and become part of the immutable image; the home
directory itself remains writable by the user.

## Relationship to Home Manager

This captures the **configuration data** part of Home Manager without its
implementation:

- no Nix store or per-user generations;
- no activation scripts, symlink farm, or service manager;
- no Home Manager option modules.

For Redox, that is the useful boundary: a declarative data model that the image
builder and, later, `snix system rebuild` can consume. A future adapter could
translate a subset of Home Manager data into this layer, but upstream Home
Manager should not be ported wholesale.

## Current limits

- Files are read-only store contents owned by the image.
- Packages are system packages, not per-user store profiles.
- User-level services and activation hooks are not implemented.
