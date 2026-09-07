{ config, ... }:

{
  # xrdp is the appliance's window to the Windows host.  Whatever the active
  # profiles put into qubix.session.command becomes the session: a plain
  # window manager for generic images, or a single-app kiosk session such as
  # Spotify.  When that command exits, xrdp ends the session and mstsc closes.
  services.xrdp = {
    enable = true;
    defaultWindowManager = config.qubix.session.command;
    openFirewall = true;
  };
}
