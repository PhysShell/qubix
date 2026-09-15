{ config, lib, pkgs, ... }:

let
  # Spotify as this appliance needs it.  The stock nixpkgs package is built for
  # a desktop, and two of its inputs bring in things a kiosk can never reach:
  #
  #   * it links libavcodec and libavformat out of ffmpeg_4, but referring to
  #     that lib output keeps all of it, libavdevice included - and
  #     libavdevice's SDL output device pulls SDL3, which pulls zenity, GTK4,
  #     gst-plugins-bad, PipeWire, BlueZ, a fax-modem DSP library and support
  #     for AJA broadcast capture cards.  The headless build of the same
  #     ffmpeg 4.4.6 decodes everything Spotify streams (aac, mp3, opus,
  #     vorbis, flac, pcm) and carries none of that.
  #
  #   * zenity is on PATH for the folder picker behind "add local files".  The
  #     kiosk has no local files and no way to open settings dialogs anyway;
  #     traced through a full startup in a VM, Spotify never touches it.
  #
  # Everything else in the wrapper stays.  Most of it is not optional: cups,
  # libayatana-appindicator and libdbusmenu are DT_NEEDED of libcef.so and the
  # Spotify binary itself, so dropping them stops the process at exec time
  # rather than saving anything.  Debug images get the stock package.
  spotify =
    if config.qubix.mode == "debug" then
      pkgs.spotify
    else
      pkgs.spotify.override {
        ffmpeg_4 = pkgs.ffmpeg_4-headless;
        zenity = pkgs.emptyDirectory;
      };

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
      spotify
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
  environment.systemPackages = [ spotify ];

  environment.etc."qubix/openbox-rc.xml".source = openboxRc;

  qubix.session.command = "${session}/bin/spotibox-session";
}
