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
  # confDir while the daemons keep running the unmodified build.
  #
  # The fix, https://github.com/NixOS/nixpkgs/pull/452303, is merged - into
  # master.  It has not been backported: both the pinned revision and the
  # current head of nixos-25.11, the branch this flake follows, still
  # interpolate pkgs.xrdp.  Swapping the overlay for the option today would
  # quietly put the stock build back on the wire, MP3 encoder and all.  Check
  # whether that is still true with
  #
  #   curl -s https://raw.githubusercontent.com/NixOS/nixpkgs/nixos-25.11/\
  #     nixos/modules/services/networking/xrdp.nix | grep ExecStart
  #
  # and when it prints cfg.package instead of pkgs.xrdp, update the flake input
  # and make this a plain services.xrdp.package assignment.  The assertions
  # below exist so that swap fails loudly rather than silently: they check what
  # systemd actually starts, not what the option says.
  nixpkgs.overlays = [
    (_final: prev: {
      xrdp = prev.xrdp.overrideAttrs (old: {
        configureFlags = builtins.filter
          (f: f != "--enable-mp3lame" && f != "--enable-opus")
          old.configureFlags;
      });
    })
  ];

  # Guard rails for the paragraph above.  Both are evaluation-only, so
  # `nix flake check` catches a regression without building an image.
  assertions = [
    {
      assertion = lib.hasPrefix "${config.services.xrdp.package}/bin/xrdp"
        config.systemd.services.xrdp.serviceConfig.ExecStart;
      message = ''
        xrdp.service does not start services.xrdp.package.  This is the
        nixpkgs#452303 bug: the module interpolates pkgs.xrdp directly, so the
        daemon runs a build this profile did not choose - including the MP3 and
        Opus encoders that make mstsc negotiate a format it then refuses to
        play.  Keep the nixpkgs overlay until the fix reaches the nixpkgs this
        flake follows.
      '';
    }
    {
      assertion =
        let flags = config.services.xrdp.package.configureFlags or [ ];
        in !(lib.elem "--enable-mp3lame" flags) && !(lib.elem "--enable-opus" flags);
      message = ''
        The xrdp this appliance ships was built with the MP3 or Opus encoder.
        mstsc will negotiate that format and then play nothing at all, while
        everything inside the guest looks healthy (neutrinolabs/xrdp#965).
      '';
    }
  ];

  security.rtkit.enable = true;

  services.pulseaudio.enable = true;
  services.pipewire.enable = false;

  # Neither pulseaudio nor pulseaudio-module-xrdp is listed here on purpose.
  # services.pulseaudio.enable installs the daemon package itself, and it may
  # install an *overridden* build (zeroconf); services.xrdp.audio.enable
  # installs the module for session autostart.  Naming the plain packages again
  # would pin a second, un-overridden copy of each into the closure — an
  # appliance carrying two PulseAudios, with an arbitrary winner in PATH.
  #
  # pavucontrol and alsa-utils are mixer-debugging tools.  The kiosk has no way
  # to launch a GTK mixer and no terminal to run speaker-test from, so they only
  # earn their place in the closure on debug images.
  environment.systemPackages = lib.optionals (config.qubix.mode == "debug") (with pkgs; [
    pavucontrol
    alsa-utils
  ]);
}
