# Services Configuration (/services)
#
# Init scripts and startup script configuration.
# The /build module generates init.toml, startup.sh, and init.d scripts.

adios:

{
  name = "services";

  options = {
    initScripts = {
      type = adios.types.attrs;
      default = {
        "00_base" = {
          text = "notify /bin/ipcd";
          directory = "usr/lib/init.d";
        };
      };
      description = "Init scripts: { name = { text, directory }; }";
    };

    startupScriptEnable = {
      type = adios.types.bool;
      default = true;
      description = "Whether to generate /startup.sh";
    };

    startupScriptText = {
      type = adios.types.string;
      default = ''
        export PATH /bin:/usr/bin
        export HOME /root
        export USER root
        export SHELL /bin/ion
        export TERM xterm-256color
        export XDG_CONFIG_HOME /etc
        echo ""
        echo "=========================================="
        echo "  Redox OS Boot Complete!"
        echo "=========================================="
        echo ""
        echo "Starting interactive shell..."
        echo "Type 'help' for commands, 'exit' to quit"
        echo ""
        /bin/ion
      '';
      description = "Content of /startup.sh";
    };
  };

  impl = { options }: options;
}
