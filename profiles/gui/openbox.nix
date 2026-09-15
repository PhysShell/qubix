{ config, lib, pkgs, ... }:

let
  debug = config.qubix.mode == "debug";
in
lib.mkIf (config.qubix.gui == "openbox") {
  # Minimal X11 desktop stack.  Openbox is enough to host Spotify and, on debug
  # images, an emergency terminal, without dragging a full desktop environment
  # into the appliance.  openbox itself reaches systemPackages through
  # services.xserver.windowManager.openbox.enable, so this profile adds nothing
  # to a production image.
  services.xserver.enable = true;
  services.xserver.windowManager.openbox.enable = true;

  # A greeter is only useful on an image somebody logs into locally.  Production
  # images drop LightDM entirely; see profiles/modes/prod.nix.
  services.xserver.displayManager.lightdm.enable = lib.mkDefault true;

  # Remote sessions get a bare Openbox unless an app profile overrides this.
  qubix.session.command = lib.mkDefault "${pkgs.openbox}/bin/openbox-session";

  # The emergency terminal is a debugging tool, not part of the product: in the
  # kiosk session Spotify covers the root window, so the Openbox menu that would
  # launch it is unreachable anyway.  Keeping xterm out of production images
  # also keeps its dependencies out of the closure - and NixOS's X server module
  # installs it on its own, so that takes an exclusion rather than just not
  # asking for it.  tests/appliance-split.nix is what noticed.
  services.xserver.excludePackages = lib.optionals (!debug) [ pkgs.xterm ];

  # xterm's compiled-in default is the bitmap "fixed" font in ISO-8859-1, which
  # carries no Cyrillic (or any non-latin) glyphs, so typing Russian over RDP
  # renders as boxes even though 75 Cyrillic-capable fonts are installed and the
  # locale is UTF-8.  Normally X resources would fix this, but nothing in this
  # image loads them: there is no display manager session and no xrdb call, and
  # ~/.Xresources would live on the persistent home disk rather than in Nix.
  # So the defaults are baked into the binary the Openbox menu actually invokes.
  environment.systemPackages = lib.optionals debug (with pkgs; [
    (lib.hiPrio (writeShellScriptBin "xterm" ''
      exec ${xterm}/bin/xterm -fa 'DejaVu Sans Mono' -fs 11 -u8 "$@"
    ''))
    xterm
  ]);
}
