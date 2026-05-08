{ config, lib, ... }:

lib.mkIf (config.qubix.mode == "prod") {
  services.openssh.enable = lib.mkDefault false;

  # TODO: Once the Spotify appliance is stable, remove the emergency terminal
  # from the production GUI profile and keep it only in debug variants.
}
