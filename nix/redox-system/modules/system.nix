# System Identity Configuration (/system)
#
# System name, version, and target triple.
# Used in manifests, boot banners, and toplevel derivation naming.

adios:

let
  t = adios.types;
in

{
  name = "system";

  options = {
    name = {
      type = t.string;
      default = "redox";
      description = "System name (used in manifest, toplevel derivation, and branding)";
    };
    version = {
      type = t.string;
      default = "0.5.0";
      description = "System version string (embedded in manifest.json)";
    };
    target = {
      type = t.string;
      default = "x86_64-unknown-redox";
      description = "Rust target triple for the system";
    };
  };

  impl = { options }: options;
}
