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
let
  esp = config.boot.loader.efi.efiSysMountPoint;

  # NixOS installs systemd-boot with systemd-boot-builder.py, and that script
  # enumerates generations by running `nix-env --list-generations`.  That one
  # call is why a machine with `nix.enable = false` still shipped Nix - and
  # with Nix came boost, the AWS SDK (S3 binary caches), libgit2, boehm-gc,
  # onetbb and the rest of its tail: 52 MiB and 43 store paths, for a
  # generation list that is always exactly one entry long on an image that is
  # replaced wholesale rather than rebuilt.
  #
  # boot.loader.external is the upstream seam for replacing the installer.
  # This is what the Python script does, minus everything an appliance cannot
  # reach: no generation enumeration, no garbage collection of old entries, no
  # memtest or EFI shell entries, no Secure Boot signing.  bootctl comes from
  # the systemd already in the closure and writes both EFI/systemd and
  # EFI/BOOT/BOOTX64.EFI - the removable path, which is the one Hyper-V's
  # firmware boots and the one the upstream image module asks for with
  # boot.loader.grub.efiInstallAsRemovable.
  #
  # It runs exactly once, inside the make-disk-image VM.  That VM's EFI
  # variables are not the appliance's, so --no-variables; the removable path
  # is what makes the image bootable without them.
  installBootLoader = pkgs.writeShellScript "qubix-install-boot-loader" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnused config.systemd.package ]}

    toplevel="$1"

    bootctl install --esp-path=${esp} --no-variables --graceful

    # Named after the store path, so a second generation could never overwrite
    # the kernel the running one booted from.
    copy_to_esp() {
      name="EFI/nixos/$(echo "$1" | sed 's|^/nix/store/||; s|/|-|g').efi"
      if [ ! -e "${esp}/$name" ]; then
        install -Dm444 "$1" "${esp}/$name.tmp"
        mv "${esp}/$name.tmp" "${esp}/$name"
      fi
      printf '/%s' "$name"
    }

    kernel=$(copy_to_esp "$(readlink -f "$toplevel/kernel")")
    initrd=$(copy_to_esp "$(readlink -f "$toplevel/initrd")")

    mkdir -p "${esp}/loader/entries"
    {
      printf 'title NixOS\n'
      printf 'version Generation 1\n'
      printf 'linux %s\n' "$kernel"
      printf 'initrd %s\n' "$initrd"
      printf 'options init=%s/init %s\n' "$toplevel" "$(cat "$toplevel/kernel-params")"
    } > "${esp}/loader/entries/nixos-generation-1.conf"

    {
      printf 'timeout %s\n' '${toString (if config.boot.loader.timeout == null then 0 else config.boot.loader.timeout)}'
      printf 'default nixos-generation-1.conf\n'
      printf 'editor no\n'
    } > "${esp}/loader/loader.conf"
  '';
in
lib.mkIf (config.qubix.mode == "prod") {
  # No remote shell into the appliance.  Debug images force this back on.
  services.openssh.enable = lib.mkForce false;

  # The X server module, and with it every desktop assumption NixOS makes once
  # it is on.  This image does run an X server - one per xrdp session - but not
  # the one this module configures: xrdp-sesman spawns Xorg from the command
  # line baked into its own sesman.ini, with xorgxrdp's module path and
  # xorg.conf, and never reads NixOS's generated /etc/X11/xorg.conf or starts
  # display-manager.service.  Upstream says as much in the xrdp module itself:
  # "xrdp can run X11 program even if services.xserver.enable = false".
  #
  # What the session needs survives, because the xrdp package hard-references
  # it: sesman.ini names the xorg-server store path, and that server has
  # xkbcomp and xkeyboard-config compiled into it, which is what makes the
  # setxkbmap call in profiles/remote/xrdp.nix work.  ~10 MiB of things xrdp
  # cannot reach leave with the module:
  #
  #   * the input driver stack - xf86-input-libinput, xf86-input-evdev,
  #     libinput, libwacom and the python3 environment libwacom carries.
  #     xorgxrdp's xorg.conf sets AutoAddDevices off and declares xrdpkeyb and
  #     xrdpmouse as its only input devices, so none of it was ever loaded.
  #   * the core bitmap fonts (font-misc-misc, font-cursor-misc, font-alias).
  #     Nothing here sets a FontPath, so `xset q` on a live session reports the
  #     font path as exactly "built-ins" - the element compiled into libXfont2,
  #     which is where "fixed" and "cursor" come from.  These three were
  #     indexed by fontconfig and then ignored by it.
  #   * xrandr, xrdb and its preprocessor mcpp, xset, xinput, xprop,
  #     xlsclients, iceauth, x11-ssh-askpass: X utilities, in an image whose
  #     production session has no terminal to type them into.
  #   * display-manager.service.  services.displayManager.enable was already
  #     forced off, but the unit is declared by the X server module rather than
  #     the display-manager one, so what shipped until now was a greeter unit
  #     with an empty ExecStart.
  #
  # Three forces that used to sit here are gone with it, because all three were
  # downstream of this switch: LightDM (the X module elects it as the default
  # display manager, and profiles/gui/openbox.nix now follows this option
  # instead of asking for a greeter unconditionally - LightDM asserts that the
  # X server is on, so that had to move), services.displayManager.enable (the X
  # module turns it on by itself, and its xsession script is what dragged in
  # feh, imlib2 and a printing Ghostscript), and gtk.iconCache.enable, whose
  # default is literally `config.services.xserver.enable`.
  # tests/appliance-split.nix asserts the outcomes, so that this stays one
  # switch and not four.
  services.xserver.enable = lib.mkForce false;

  # nixos/modules/virtualisation/hyperv-image.nix switches this on for every
  # image it builds, and it exists for one scenario: somebody enlarged the
  # virtual disk after the image was written, so the partition table still
  # describes the old size.  `growpart` then stretches the root partition and
  # systemd-growfs stretches the filesystem onto it.
  #
  # Qubix never enlarges the disk.  tools/qubixctl.ps1 downloads a .vhdx.gz,
  # gunzips it, attaches it and starts the VM - there is no Resize-VHD
  # anywhere in the controller, and `recreate` replaces the image rather than
  # growing it.  So the service has run on every boot of every Spotibox,
  # looked at a partition that already fills the disk, and gone home.
  #
  # ~970 KiB: gptfdisk (sgdisk, which growpart shells out to) and
  # cloud-utils-guest.  fileSystems."/".autoResize stays on: it is the same
  # safety net one layer up, it costs nothing extra, and it is what would
  # notice if the partition ever did change size underneath us.
  boot.growPartition = lib.mkForce false;

  # See the installBootLoader script above: this is the same systemd-boot, put
  # on the ESP by a shell script instead of by a Python one that needs Nix.
  # Debug images keep the stock builder, because `nixos-rebuild switch` inside
  # the guest is a real debugging workflow there and it wants both.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.external = {
    enable = true;
    installHook = installBootLoader;
  };

  # Nothing writes EFI variables: the image is built in a throwaway VM whose
  # firmware is not the appliance's, and Hyper-V boots the removable path.
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

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

  # No package manager in a machine that cannot rebuild itself.  This is worth
  # exactly 9 MiB and not the 49 the nix closure suggests: the systemd-boot
  # generation builder interpolates ${"$"}{config.nix.package}/bin/nix-env, so the
  # package stays whatever this says.  What does leave is the daemon, its
  # socket, and the OpenSSH client that was only there because nix-daemon
  # carries ssh on its PATH for remote builds.
  nix.enable = false;

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

  # environment.corePackages calls itself "core packages for a normal
  # interactive system", and that is exactly what this is not.  Two upstream
  # modules add to it unconditionally, with no option to refuse:
  # programs/ssh.nix contributes an OpenSSH client to a machine whose sshd is
  # forced off, and tasks/network-interfaces.nix contributes BIND's `host` to
  # one with static resolvers.  So the list is replaced rather than filtered.
  #
  # What stays is what something on this image can still call through
  # /run/current-system/sw/bin: the shell users log into, the GNU text and file
  # utilities system scripts assume, login/su from shadow, the process and
  # mount tools, and ip.  Everything a systemd unit runs is an absolute store
  # path and does not depend on this list at all.
  #
  # Deliberately not busybox: the scripts that survive here expect GNU
  # semantics, and swapping the implementation to save a few megabytes is how
  # you get a bug report six months later about an option that silently means
  # something else.
  environment.corePackages = lib.mkForce (with pkgs; [
    bashInteractive
    coreutils
    findutils
    gnugrep
    gnused
    gawk
    util-linux
    procps
    shadow
    iproute2
    # 100 KiB, and the first thing the smoke test called after boot.  The
    # allowlist is for things that cost megabytes, not for winning arguments
    # about whether anyone still types hostname(1).
    hostname-debian
    getent
    getconf
    acl
    attr
    libcap
    ncurses
    which
    stdenv.cc.libc
  ]);

  # NixOS's "interactive system" convenience set: perl, rsync, strace.
  environment.defaultPackages = lib.mkForce [ ];

  # nixos-rebuild, nixos-install, nixos-enter, nixos-generate-config,
  # nixos-option, nixos-version.  The image is built on the host and replaced
  # wholesale on every recreate - it never reconfigures itself in place.
  system.disableInstallerTools = true;
}
