{ config, lib, pkgs, ... }:

lib.mkIf (config.qubix.audio == "pulseaudio-xrdp") {
  # Stable baseline for Windows mstsc audio redirection.
  #
  # NixOS xrdp audio support expects PulseAudio modules on the server side.
  # PipeWire was deliberately not selected for this baseline because the
  # Hyper-V + xrdp appliance prototype produced Dummy Output / broken audio with
  # PipeWire while PulseAudio+xrdp worked.
  services.xrdp = {
    enable = true;
    defaultWindowManager = "openbox-session";
    openFirewall = true;

    audio = {
      enable = true;
    };
  };

  security.rtkit.enable = true;

  services.pulseaudio.enable = true;
  services.pipewire.enable = false;

  environment.systemPackages = with pkgs; [
    pavucontrol
    alsa-utils
    pulseaudio
    pulseaudio-module-xrdp
  ];
}
