{ config, lib, pkgs, ... }:

lib.mkIf (config.qubix.gui == "openbox") {
  # Minimal X11 desktop stack. Openbox is enough to host Spotify, pavucontrol
  # and an emergency terminal without dragging a full desktop environment into
  # the appliance image.
  services.xserver.enable = true;
  services.xserver.displayManager.lightdm.enable = true;
  services.xserver.windowManager.openbox.enable = true;

  # Remote sessions get a bare Openbox unless an app profile overrides this.
  qubix.session.command = lib.mkDefault "${pkgs.openbox}/bin/openbox-session";

  environment.systemPackages = with pkgs; [
    openbox
    xterm
  ];
}
