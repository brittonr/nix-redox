# Complete counterpart of before.nix: only hostname changes.
{
  hostname = "browser-demo-changed";
  timezone = "UTC";
  networking = { enable = false; mode = "auto"; dns = [ ]; };
  graphics = { enable = false; resolution = "1024x768"; };
}
