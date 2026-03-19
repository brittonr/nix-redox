# Programs Configuration (/programs)
#
# Declarative per-program configuration.
# Generates config files in /etc for each enabled program.
# Inspired by NixOS programs.* options.

adios:

let
  t = adios.types;

  ionConfig = t.struct "IonConfig" {
    enable = t.bool;
    prompt = t.string;
    initExtra = t.string;
  };

  helixConfig = t.struct "HelixConfig" {
    enable = t.bool;
    theme = t.string;
  };

  httpdConfig = t.struct "HttpdConfig" {
    enable = t.bool;
    port = t.int;
    rootDir = t.string;
  };

  cargoConfig = t.struct "CargoConfig" {
    buildJobs = t.int;
    home = t.string;
  };
in

{
  name = "programs";

  options = {
    ion = {
      type = ionConfig;
      default = {
        enable = true;
        # Literal hostname — Ion's \$USER expansion inside double-quoted PROMPT
        # causes "Variable does not exist" errors. Profiles can override.
        prompt = "redox# ";
        initExtra = "";
      };
      description = "Ion shell configuration";
    };
    helix = {
      type = helixConfig;
      default = {
        enable = false;
        theme = "default";
      };
      description = "Helix editor configuration";
    };
    editor = {
      type = t.string;
      default = "/bin/sodium";
      description = "Default system editor binary path";
    };
    httpd = {
      type = httpdConfig;
      default = {
        enable = false;
        port = 8080;
        rootDir = "/var/www";
      };
      description = "Simple HTTP server configuration";
    };
    cargo = {
      type = cargoConfig;
      default = {
        buildJobs = 4;
        home = "/root/.cargo";
      };
      description = "Cargo build configuration (used when self-hosting toolchain is present)";
    };
  };

  impl = { options }: options;
}
