{ config, lib, pkgs, ... }:

lib.mkIf (config.qubix.app == "spotify") {
  environment.systemPackages = with pkgs; [
    spotify
  ];

  # TODO: Add Spotify Openbox autostart after the final login/session model is
  # fixed. The likely location is /etc/xdg/openbox/autostart or a user-level
  # ~/.config/openbox/autostart file.
}
