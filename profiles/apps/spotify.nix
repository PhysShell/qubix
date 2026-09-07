{ config, lib, pkgs, ... }:

let
  # Stock Openbox rc.xml plus one rule: every normal Spotify window is
  # undecorated and maximised.  The RDP canvas then *is* the Spotify window,
  # which is as close to "Spotify as a native window" as xrdp gets — xrdp has
  # no RemoteApp support, so a seamless per-window mode is not on the table.
  # Dialogs are excluded by type="normal" so popups keep their frames.
  openboxRc = pkgs.runCommand "qubix-openbox-rc.xml" { } ''
    cp ${pkgs.openbox}/etc/xdg/openbox/rc.xml $out
    chmod +w $out
    substituteInPlace $out --replace-fail '</applications>' '  <application class="Spotify" type="normal">
    <decor>no</decor>
    <maximized>yes</maximized>
    <focus>yes</focus>
  </application>
</applications>'
  '';

  # Session script used by xrdp.  Openbox runs in the background purely as a
  # window manager; Spotify is the session.  Quitting Spotify ends the session,
  # so the mstsc window closes like an ordinary application window would.
  session = pkgs.writeShellApplication {
    name = "spotibox-session";
    runtimeInputs = [
      pkgs.openbox
      pkgs.spotify
      pkgs.xorg.xsetroot
    ];
    text = ''
      xsetroot -solid '#121212' || true
      openbox --config-file /etc/qubix/openbox-rc.xml &
      wm=$!
      # Let the window manager come up so the first Spotify window is
      # managed (and therefore maximised) instead of appearing unmanaged.
      sleep 1
      spotify || true
      kill "$wm" 2>/dev/null || true
    '';
  };
in
lib.mkIf (config.qubix.app == "spotify") {
  environment.systemPackages = [ pkgs.spotify ];

  environment.etc."qubix/openbox-rc.xml".source = openboxRc;

  qubix.session.command = "${session}/bin/spotibox-session";
}
