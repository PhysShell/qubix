{ config, lib, ... }:

# Production mode seals the machine into an appliance.  The only thing anyone
# can reach over RDP is the kiosk session, and everything that exists purely to
# make a NixOS box pleasant to sit in front of stays out of the image.
#
# Every line here is also a closure decision.  NixOS does not copy the build
# machine's /nix/store into the VHDX: it copies the closure of
# `system.build.toplevel`, so a package only ships if something still refers to
# it.  Dropping a root is therefore the only way to drop its dependencies -
# `nix-store --gc` inside the guest would be shouting at the wrong end of the
# pipeline.  `tools/closure.sh report` says what a root actually costs and
# `tools/closure.sh why NAME` says who is still holding on to it.
#
# The sizes quoted below were measured against nixpkgs 25.11 with
# tools/closure.sh; they are there to show the order of magnitude, not as
# numbers to trust forever.
lib.mkIf (config.qubix.mode == "prod") {
  # No remote shell into the appliance.  Debug images force this back on.
  services.openssh.enable = lib.mkForce false;

  # No local login screen and no X session plumbing around it.  The session is
  # started by xrdp, which execs qubix.session.command directly; nothing in the
  # Spotibox path ever renders a greeter or reads an .xsession file.  The
  # Hyper-V console keeps its text login.
  #
  # Both lines are needed.  services.xserver.enable turns LightDM on by itself
  # (as the default display manager) and switches on the display-manager layer
  # unconditionally, and that layer is what puts NixOS's xsession script into
  # the closure - which drags in feh, imlib2 and, through it, a full
  # Ghostscript with X support, for an image that cannot print.
  services.xserver.displayManager.lightdm.enable = lib.mkForce false;
  services.displayManager.enable = lib.mkForce false;

  # ~770 MiB: Mesa and the LLVM it carries for llvmpipe.  Hyper-V has no GPU
  # to drive, and Spotify is a CEF application that ships its own software
  # renderer: traced in a VM with this switched off, it loads
  # share/spotify/libEGL.so, libGLESv2.so and libvulkan.so.1 - ANGLE over
  # SwiftShader - puts its window up, and never looks at /run/opengl-driver
  # at all.  Xorg keeps libglvnd and mesa-libgbm, which are separate and small;
  # what leaves is the driver set nothing here can use.
  hardware.graphics.enable = lib.mkForce false;

  # ~700 MB of speech synthesis.  services/misc/graphical-desktop.nix turns
  # speech-dispatcher on for anything with a graphical session ("default
  # guessed conservatively", says the module), and speech-dispatcher pulls in
  # espeak-ng, flite and the MBROLA voice corpus - which alone is 648 MB of
  # diphone recordings.  Spotify does not talk to the user.
  services.speechd.enable = false;

  # ~185 MB: a complete nixpkgs source tree, pinned into /etc/nix/registry.json
  # and NIX_PATH so that `nix run nixpkgs#hello` works offline on the appliance.
  # Nothing on this image runs nix commands - the system is built on the host
  # and replaced wholesale - and upstream documents the closure cost of leaving
  # these on.  setNixPath is implemented through the registry, so the two have
  # to go together; an assertion enforces that.
  nixpkgs.flake.setFlakeRegistry = false;
  nixpkgs.flake.setNixPath = false;

  # Man pages, info pages, the NixOS manual and every package's doc output, in
  # an image whose production GUI has no terminal to read them from.  man.enable
  # has to be named separately: nixos/modules/misc/man-db.nix keys off
  # documentation.man.enable alone, so man-db ships even with documentation
  # switched off wholesale.
  documentation.enable = lib.mkDefault false;
  documentation.man.enable = lib.mkDefault false;

  # NixOS's "interactive system" convenience set: perl, rsync, strace.  perl
  # stays in the closure regardless (the activation script is written in it),
  # but nothing else here has a reason to ship.
  environment.defaultPackages = lib.mkForce [ ];

  # nixos-rebuild, nixos-install, nixos-enter, nixos-generate-config,
  # nixos-option, nixos-version.  The image is built on the host and replaced
  # wholesale on every recreate - it never reconfigures itself in place.
  system.disableInstallerTools = true;
}
