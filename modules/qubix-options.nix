{ lib, ... }:

{
  options.qubix = {
    mode = lib.mkOption {
      type = lib.types.enum [ "debug" "prod" ];
      default = "prod";
      description = "Selects debug or production-oriented appliance defaults.";
    };

    gui = lib.mkOption {
      type = lib.types.enum [ "none" "openbox" ];
      default = "openbox";
      description = "Selects the graphical shell profile.";
    };

    audio = lib.mkOption {
      type = lib.types.enum [ "none" "pulseaudio-xrdp" "pipewire-easyeffects" ];
      default = "none";
      description = "Selects the appliance audio stack.";
    };

    app = lib.mkOption {
      type = lib.types.enum [ "none" "spotify" ];
      default = "none";
      description = "Selects the single-purpose application profile.";
    };

    kernel = lib.mkOption {
      type = lib.types.enum [ "default" ];
      default = "default";
      description = "Selects the kernel profile. More kernel variants are later goals.";
    };

    labPassword = lib.mkOption {
      type = lib.types.str;
      default = "1234";
      description = "Disposable lab password used for generated appliance users.";
    };

    networkLockdown.enable = lib.mkEnableOption "restricted outbound network policy";

    network = {
      staticIp = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Static IPv4 address for the appliance (e.g. "192.168.250.10").
          Null keeps DHCP on the Default Switch.  When set, the image is built
          with a fixed address and qubixctl creates a dedicated Hyper-V NAT
          switch automatically.
        '';
      };

      prefixLength = lib.mkOption {
        type = lib.types.int;
        default = 24;
        description = "Subnet prefix length for the static address.";
      };

      gateway = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Default gateway when staticIp is set.";
      };

      nameservers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "1.1.1.1" "8.8.8.8" ];
        description = "DNS resolvers used when staticIp is set.";
      };
    };
  };
}
