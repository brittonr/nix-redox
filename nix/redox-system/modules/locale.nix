# Locale Configuration (/locale)
#
# Sets LANG, LC_ALL, and per-category LC_* environment variables.
# Redox's relibc is C-locale only — setlocale() always returns "C".
# This module sets env vars for software that reads them (Rust's
# std::env::var("LANG"), Python's locale.getdefaultlocale(), etc.).
# No locale data files are installed.

adios:

let
  t = adios.types;
in

{
  name = "locale";

  options = {
    lang = {
      type = t.string;
      default = "C";
      description = "Default locale (LANG). Set to e.g. \"en_US.UTF-8\" for UTF-8 signaling.";
    };
    lcAll = {
      type = t.string;
      default = "";
      description = "Override all LC_* categories (LC_ALL). Empty means no override.";
    };
    lcCollate = {
      type = t.string;
      default = "";
      description = "Collation order (LC_COLLATE). Empty inherits from LANG.";
    };
    lcCtype = {
      type = t.string;
      default = "";
      description = "Character classification (LC_CTYPE). Empty inherits from LANG.";
    };
    lcMessages = {
      type = t.string;
      default = "";
      description = "Message language (LC_MESSAGES). Empty inherits from LANG.";
    };
    lcMonetary = {
      type = t.string;
      default = "";
      description = "Monetary formatting (LC_MONETARY). Empty inherits from LANG.";
    };
    lcNumeric = {
      type = t.string;
      default = "";
      description = "Numeric formatting (LC_NUMERIC). Empty inherits from LANG.";
    };
    lcTime = {
      type = t.string;
      default = "";
      description = "Time/date formatting (LC_TIME). Empty inherits from LANG.";
    };
  };

  impl = { options }: options;
}
