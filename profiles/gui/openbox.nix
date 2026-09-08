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

  # xterm's compiled-in default is the bitmap "fixed" font in ISO-8859-1, which
  # carries no Cyrillic (or any non-latin) glyphs, so typing Russian over RDP
  # renders as boxes even though 75 Cyrillic-capable fonts are installed and the
  # locale is UTF-8.  Normally X resources would fix this, but nothing in this
  # image loads them: there is no display manager session and no xrdb call, and
  # ~/.Xresources would live on the persistent home disk rather than in Nix.
  # So the defaults are baked into the binary the Openbox menu actually invokes.
  environment.systemPackages = with pkgs; [
    (lib.hiPrio (writeShellScriptBin "xterm" ''
      exec ${xterm}/bin/xterm -fa 'DejaVu Sans Mono' -fs 11 -u8 "$@"
    ''))
    openbox
    xterm
  ];
}
