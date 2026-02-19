# Logging Configuration (/logging)
#
# System log levels, destinations, and retention.

adios:

let
  t = adios.types;

  logLevel = t.enum "LogLevel" [
    "debug"
    "info"
    "warn"
    "error"
    "off"
  ];
in

{
  name = "logging";

  options = {
    level = {
      type = logLevel;
      default = "info";
      description = "System-wide log level";
    };
    kernelLogLevel = {
      type = logLevel;
      default = "warn";
      description = "Kernel log verbosity";
    };
    logToFile = {
      type = t.bool;
      default = true;
      description = "Write logs to filesystem";
    };
    logPath = {
      type = t.string;
      default = "/var/log";
      description = "Log directory path";
    };
    maxLogSizeMB = {
      type = t.int;
      default = 10;
      description = "Maximum size per log file in megabytes";
    };
    persistAcrossBoot = {
      type = t.bool;
      default = false;
      description = "Preserve log files across reboots";
    };
  };

  impl = { options }: options;
}
