# Power Management Configuration (/power)
#
# ACPI, shutdown/reboot behavior, idle timeout actions.

adios:

let
  t = adios.types;
in

{
  name = "power";

  options = {
    acpiEnable = {
      type = t.bool;
      default = true;
      description = "Enable ACPI power management daemon";
    };
    powerAction = {
      type = t.enum "PowerAction" [
        "shutdown"
        "reboot"
        "suspend"
        "none"
      ];
      default = "shutdown";
      description = "Action on power button press";
    };
    idleAction = {
      type = t.enum "IdleAction" [
        "none"
        "suspend"
        "shutdown"
      ];
      default = "none";
      description = "Action on idle timeout";
    };
    idleTimeoutMinutes = {
      type = t.int;
      default = 30;
      description = "Minutes of idle before idleAction triggers";
    };
    rebootOnPanic = {
      type = t.bool;
      default = false;
      description = "Automatically reboot on kernel panic";
    };
  };

  impl = { options }: options;
}
