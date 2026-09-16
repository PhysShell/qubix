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
    ../profiles/kernel/hyperv.nix
  ];

  networking.hostName = "spotibox";

  # Measured rather than guessed, now that the closure is 1.5 GiB: an 8 GiB
  # root leaves 6.4 GiB free after the system, against 2.4 GiB at 4 GiB and
  # 28.5 GiB at the old 30.  The virtual size is not free even on a dynamic
  # VHDX - ext4's inode tables are written lazily after first mount, so a
  # 30 GiB filesystem eventually allocates ~656 MiB of metadata against
  # ~231 MiB here - and systemd sizes the journal at 10% of the filesystem,
  # which is 3 GiB of logs at 30 GiB and 819 MiB at 8.
  virtualisation.diskSize = 8 * 1024;

  qubix = {
    mode = "prod";
    gui = "openbox";
    audio = "pulseaudio-xrdp";
    app = "spotify";
    kernel = "hyperv";
    # RDP only reports the client's *active* layout, so a Russian typist
    # connecting while Windows sits on the US layout would otherwise get a
    # single Latin group and nothing to toggle to.  Name both explicitly.
    keyboard.layouts = "us,ru";

    homeDisk.sizeMiB = 16 * 1024;
    network = { staticIp = "192.168.250.10"; gateway = "192.168.250.1"; };
  };
}
