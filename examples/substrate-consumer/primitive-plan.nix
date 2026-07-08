# Minimal public Redox substrate primitive plan used by docs and tests.
# This file intentionally contains only substrate primitives, not Adios path keys.

let
  substrateIpv6PrefixLength = 64;
in
{
  services.exampled = {
    description = "Example substrate service";
    command = "/bin/exampled";
    argv = [
      "--flag"
      "value with spaces"
    ];
    type = "nowait";
    wantedBy = "rootfs";
    after = [ "smolnetd" ];
    environment = {
      EXAMPLE_MODE = "substrate";
    };
  };

  networking = {
    enable = true;
    mode = "static";
    hostname = "redox-substrate";
    dns = [ "2001:4860:4860::8888" ];
    searchDomains = [
      "svc.example"
      "example"
    ];
    defaultRouter = "2001:db8::1";
    interfaces.eth0.addresses = [
      {
        address = "2001:db8::10";
        prefixLength = substrateIpv6PrefixLength;
        gateway = "2001:db8::1";
      }
    ];
  };

  filesystem = {
    directories = [ "/srv/example" ];
    files."etc/redox-substrate.txt" = {
      text = "hello from the public substrate fixture\n";
      mode = "0644";
    };
  };
}
