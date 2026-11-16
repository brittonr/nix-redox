# Complete, directly usable configuration for the bounded demo. Package,
# user and service sets are intentionally retained from the image manifest;
# this fixture does not resolve/rebuild the system package set.
{
  hostname = "browser-demo";
  timezone = "UTC";
  networking = { enable = false; mode = "auto"; dns = [ ]; };
  graphics = { enable = false; resolution = "1024x768"; };
}
