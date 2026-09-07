{ ... }:

{
  imports = [
    ../profiles/base.nix
    ../profiles/users.nix
    ../profiles/storage/persistent-home.nix
    ../profiles/remote/xrdp.nix
    ../profiles/gui/openbox.nix
    ../profiles/audio/pulseaudio-xrdp.nix
    ../profiles/apps/spotify.nix
    ../profiles/security/minimal.nix
    ../profiles/modes/debug.nix
    ../profiles/modes/prod.nix
    ../profiles/kernel/default.nix
  ];

  networking.hostName = "spotibox";

  # Spotify + GUI require more space than the default 8 GB disk. Need 30 GB o_O
  virtualisation.diskSize = 30 * 1024;

  qubix = {
    mode = "prod";
    gui = "openbox";
    audio = "pulseaudio-xrdp";
    app = "spotify";
    kernel = "default";
    homeDisk.sizeMiB = 16 * 1024;
    network = { staticIp = "192.168.250.10"; gateway = "192.168.250.1"; };
  };
}
