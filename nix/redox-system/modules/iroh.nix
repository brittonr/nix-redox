# iroh P2P Networking (/iroh)
#
# Configuration for the iroh scheme daemon (irohd).
# Provides P2P QUIC networking via the iroh: scheme.

adios:

let
  t = adios.types;
  serviceType = import ../lib/service-type.nix { inherit t; };

  peerType = t.struct "IrohPeer" {
    name = t.string;
    nodeId = t.string;
  };
in

{
  name = "iroh";

  options = {
    enable = {
      type = t.bool;
      default = false;
      description = "Enable iroh P2P networking scheme daemon";
    };
    keyPath = {
      type = t.string;
      default = "/etc/iroh/node.key";
      description = "Path to the node secret key file (generated on first boot if absent)";
    };
    peersPath = {
      type = t.string;
      default = "/etc/iroh/peers.json";
      description = "Path to the peers configuration file";
    };
    peers = {
      type = t.listOf peerType;
      default = [ ];
      description = "Pre-configured peers (name/nodeId pairs)";
    };
    services = {
      type = t.attrsOf serviceType;
      description = "Iroh services (computed from module options)";
      defaultFunc =
        { options, ... }:
        if !options.enable then
          { }
        else
          {
            irohd = {
              description = "iroh P2P networking scheme daemon";
              command = "/bin/irohd";
              type = "nowait";
              args = "--key-path ${options.keyPath} --peers-path ${options.peersPath}";
              wantedBy = "rootfs";
              enable = true;
              after = [ "smolnetd" ];
              environment = { };
              priority = 50;
            };
          };
    };
  };

  impl = { options }: options;
}
