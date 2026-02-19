# Time & Identity Configuration (/time)
#
# Hostname, timezone, NTP, hardware clock settings.

adios:

let
  t = adios.types;
in

{
  name = "time";

  options = {
    hostname = {
      type = t.string;
      default = "redox";
      description = "System hostname";
    };
    timezone = {
      type = t.string;
      default = "UTC";
      description = "Timezone in Olson format (e.g. America/New_York)";
    };
    ntpEnable = {
      type = t.bool;
      default = false;
      description = "Enable NTP time synchronization";
    };
    ntpServers = {
      type = t.listOf t.string;
      default = [
        "pool.ntp.org"
      ];
      description = "NTP server addresses";
    };
    hwclock = {
      type = t.enum "HWClock" [
        "utc"
        "localtime"
      ];
      default = "utc";
      description = "Hardware clock mode";
    };
  };

  impl = { options }: options;
}
