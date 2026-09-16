{ config, lib, pkgs, ... }:

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

  # `services.graphical-desktop.enable` follows services.xserver.enable around
  # and installs "bits and pieces required for a graphical desktop session":
  # nixos-icons and xdg-utils.  xdg-utils is a pile of Perl scripts, and it is
  # the only thing holding perl in this image - 62 MiB of it, activation script
  # or no activation script.  A kiosk has no MIME associations to look up, no
  # menu to build and no browser for xdg-open to reach.
  services.graphical-desktop.enable = lib.mkForce false;

  # The xrdp module switches all of these on for a desktop it assumes is on the
  # other end.  There is no desktop; there is one maximised window.
  xdg.autostart.enable = lib.mkForce false;
  xdg.menus.enable = lib.mkForce false;
  xdg.mime.enable = lib.mkForce false;
  xdg.icons.enable = lib.mkForce false;
  xdg.sounds.enable = lib.mkForce false;

  # gtk.iconCache keys off services.xserver.enable rather than off xdg.icons,
  # so with the icon theme gone its post-build hook runs `find` over a
  # share/icons that no longer exists and fails the system-path build.
  gtk.iconCache.enable = lib.mkForce false;

  # ~60 MiB: the default set is DejaVu, FreeFont, Gyre, Liberation, Unifont and
  # Noto Color Emoji.  This appliance renders Latin, Cyrillic and the emoji
  # people put in playlist names.  DejaVu covers the first two - it is also
  # what the debug xterm is pinned to - and the emoji font covers the third.
  fonts.enableDefaultPackages = lib.mkForce false;
  fonts.packages = [ pkgs.dejavu_fonts pkgs.noto-fonts-color-emoji ];

  # Avahi is in the base security profile because "spotibox.local" makes the
  # Default Switch tolerable when DHCP moves the address around.  This machine
  # has a static address, a static gateway and static resolvers, so the daemon,
  # its NSS module and its multicast hole in the firewall serve a workflow
  # production does not have.
  services.avahi.enable = lib.mkForce false;

  # The appliance's user list is what the image says it is.
  users.mutableUsers = false;

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

  # ~57 MiB of Perl, and it took two removals to see the real holder.  With
  # xdg-utils gone the only thing left pulling perl in is the activation
  # script itself - setup-etc.pl and update-users-groups.pl - which is exactly
  # what nixpkgs' own profiles/perlless.nix replaces: an overlayfs /etc instead
  # of the script that populates it, and userborn instead of the one that
  # creates users.  Both want systemd in the initrd.  The /etc overlay is
  # upstream-experimental and stays mutable, which xrdp needs: it writes its
  # self-signed certificate into /etc/xrdp on first start.
  boot.initrd.systemd.enable = true;
  system.etc.overlay.enable = true;
  services.userborn.enable = true;

  # The list of things this image has already been caught shipping.  A closure
  # budget only says "bigger"; a package can come back transitively while
  # something else shrinks and the total stays inside the budget.  This is the
  # same guard nixpkgs uses in perlless.nix, pointed at our own ghosts.
  system.forbiddenDependenciesRegexes = [
    "perl"
    "speech-dispatcher"
    "mbrola"
    "espeak"
    "flite"
    "freepats"
    "ghostscript"
    "zenity"
    "pavucontrol"
    "xterm"
  ];

  # NixOS's "interactive system" convenience set: perl, rsync, strace.
  environment.defaultPackages = lib.mkForce [ ];

  # nixos-rebuild, nixos-install, nixos-enter, nixos-generate-config,
  # nixos-option, nixos-version.  The image is built on the host and replaced
  # wholesale on every recreate - it never reconfigures itself in place.
  system.disableInstallerTools = true;
}
