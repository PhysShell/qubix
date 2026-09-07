{ config, lib, pkgs, ... }:

lib.mkIf (config.qubix.audio == "pulseaudio-xrdp") {
  # Stable baseline for Windows mstsc audio redirection.
  #
  # NixOS xrdp audio support expects PulseAudio modules on the server side.
  # PipeWire was deliberately not selected for this baseline because the
  # Hyper-V + xrdp appliance prototype produced Dummy Output / broken audio with
  # PipeWire while PulseAudio+xrdp worked.
  #
  # The xrdp server itself is configured in profiles/remote/xrdp.nix; this
  # profile only wires the audio path into it.
  services.xrdp.audio.enable = true;

  # mstsc negotiates WAVE_FORMAT_MPEGLAYER3 whenever xrdp offers it and then
  # plays nothing at all.  Everything inside the guest looks healthy while this
  # happens - the sink runs, it is not muted, chansrv accepts the socket and
  # reports a round trip time - but the host stays silent, because mstsc simply
  # drops the MP3 stream (neutrinolabs/xrdp#965).  Building xrdp without the MP3
  # and Opus encoders leaves PCM as the only negotiable format, and every RDP
  # client decodes that.  PCM costs ~176 kB/s, which is nothing next to the
  # video channel this appliance already pushes.
  #
  # This must be an overlay, not services.xrdp.package: the NixOS xrdp module
  # declares that option but hardcodes pkgs.xrdp in the ExecStart lines of both
  # xrdp.service and xrdp-sesman.service, so setting the option rebuilds only
  # confDir while the daemons keep running the unmodified build.  A fix is
  # already open upstream as https://github.com/NixOS/nixpkgs/pull/452303;
  # once it lands this can go back to a plain services.xrdp.package assignment.
  nixpkgs.overlays = [
    (_final: prev: {
      xrdp = prev.xrdp.overrideAttrs (old: {
        configureFlags = builtins.filter
          (f: f != "--enable-mp3lame" && f != "--enable-opus")
          old.configureFlags;
      });
    })
  ];

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
