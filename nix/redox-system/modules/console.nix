# Console Configuration (/console)
#
# Text-mode framebuffer console settings for the initfs environment.
# Controls fbcond VT number, inputd enable/VT, and boot log display.
# These options only take effect when initfs graphics is enabled
# (graphics.enable or boot.initfsEnableGraphics).

adios:

let
  t = adios.types;
in

{
  name = "console";

  options = {
    fbcondVT = {
      type = t.int;
      default = 2;
      description = "Virtual terminal number for fbcond (text console). Must not conflict with inputd VT or Orbital VT.";
    };
    inputdVT = {
      type = t.int;
      default = 1;
      description = "Virtual terminal number for inputd (input daemon). Must not conflict with fbcond VT or Orbital VT.";
    };
    inputd = {
      type = t.bool;
      default = true;
      description = "Enable inputd (keyboard/mouse input daemon) in initfs.";
    };
    bootLog = {
      type = t.bool;
      default = true;
      description = "Enable fbbootlogd (framebuffer boot log display) in initfs.";
    };
  };

  impl = { options }: options;
}
