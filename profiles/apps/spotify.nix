{ config, lib, pkgs, ... }:

lib.mkIf (config.qubix.app == "spotify") {
  environment.systemPackages = with pkgs; [
    spotify
  ];

  # The appliance exists to run one app, so Spotify launches with the Openbox
  # session for both the console `user` and the xrdp `rdp` user. openbox-session
  # sources /etc/xdg/openbox/autostart before any per-user autostart, which
  # keeps the behaviour declarative and identical for both accounts.
  environment.etc."xdg/openbox/autostart" = lib.mkIf (config.qubix.gui == "openbox") {
    text = ''
      ${pkgs.spotify}/bin/spotify &
    '';
  };
}
