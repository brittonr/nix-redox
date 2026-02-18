# Services Configuration (/services)
#
# Init scripts and startup configuration.

adios:

let
  t = adios.types;

  initScriptType = t.struct "InitScript" {
    text = t.string;
    directory = t.string;
  };
in

{
  name = "services";

  options = {
    initScripts = {
      type = t.attrsOf initScriptType;
      default = {
        "00_base" = {
          text = "notify /bin/ipcd";
          directory = "usr/lib/init.d";
        };
      };
      description = "Init scripts to run during boot";
    };
    startupScriptEnable = {
      type = t.bool;
      default = true;
      description = "Enable startup script";
    };
    startupScriptText = {
      type = t.string;
      default = ''
        #!/bin/sh
        echo ""
        echo "Welcome to Redox OS!"
        echo ""
        /bin/ion
      '';
      description = "Content of the startup script";
    };
  };

  impl = { options }: options;
}
