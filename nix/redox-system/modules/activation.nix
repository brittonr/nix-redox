# Activation Scripts (/activation)
#
# User-extensible hooks that run during `snix system switch`.
# Inspired by NixOS system.activationScripts.
#
# Scripts are stored in the rootTree at /etc/redox-system/activation.d/
# and executed in dependency order during activation. Failures are
# non-fatal (logged as warnings).

adios:

let
  t = adios.types;

  activationScriptType = t.struct "ActivationScript" {
    # Script content (shell commands)
    text = t.string;
    # Names of other scripts that must run before this one
    deps = t.listOf t.string;
  };
in

{
  name = "activation";

  options = {
    scripts = {
      type = t.attrsOf activationScriptType;
      default = { };
      description = "Named activation scripts run during `snix system switch`. Each script has text (shell commands) and deps (list of script names to run first). Scripts run non-interactively as root.";
    };
  };

  impl = { options }: options;
}
