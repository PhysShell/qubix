{ pkgs, lib, prod, debug }:

# Evaluation-only guard for the production/debug split.
#
# The closure budget in CI catches an image that got *bigger*; this catches the
# reason it usually happens — a tool that belongs in the debug image quietly
# landing in the production one.  Everything here is an option or a package
# name, so `nix flake check --no-build` evaluates it in seconds without
# building a system, and the failure names the rule instead of handing you a
# size delta to investigate.
#
# Runtime behaviour is covered by two VM tests: tests/spotibox-basic.nix boots
# the image and checks what it does and does not contain, and
# tests/xrdp-session.nix asks xrdp for a real session and checks that the X
# server, the keyboard layouts, Openbox and the Spotify window all come up —
# which is what stands behind turning `services.xserver.enable` off.  The one
# property that needs the image derivation rather than the config — that no
# nixpkgs channel is copied into the production VHDX — is checked by
# `tools/closure.sh check`.

let
  inherit (lib) concatMapStrings concatStringsSep filter getName;

  # environment.systemPackages is the list NixOS turns into
  # /run/current-system/sw, and config/system-path.nix folds
  # environment.defaultPackages into it, so this one list covers both.
  names = cfg: map getName cfg.environment.systemPackages;

  prodNames = names prod;
  debugNames = names debug;

  pkgOf = name: cfg: lib.findFirst (p: getName p == name) null cfg.environment.systemPackages;
  spotifyOf = pkgOf "spotify";
  openboxOf = pkgOf "openbox";

  has = haystack: needle: builtins.elem needle haystack;

  # Tools with no way to be reached from a kiosk session: the Openbox menu is
  # covered by a maximised, undecorated Spotify window, and there is no
  # terminal to type in even if it were not.
  debugOnly = [ "xterm" "pavucontrol" "alsa-utils" "man-db" ];

  # NixOS's environment.defaultPackages.  Cleared in prod, so none of these
  # should appear as a system package there.
  interactiveExtras = [ "perl" "rsync" "strace" ];

  rules = [
    {
      name = "prod: no debug tooling in systemPackages";
      ok = !(lib.any (has prodNames) debugOnly);
      detail = "found: ${concatStringsSep " " (filter (has prodNames) debugOnly)}";
    }
    {
      name = "prod: environment.defaultPackages is empty";
      ok = prod.environment.defaultPackages == [ ]
        && !(lib.any (has prodNames) interactiveExtras);
      detail = "found: ${concatStringsSep " " (filter (has prodNames) interactiveExtras)}";
    }
    {
      name = "prod: installer tools disabled";
      ok = prod.system.disableInstallerTools
        && !prod.system.tools.nixos-rebuild.enable;
      detail = "system.disableInstallerTools = ${lib.boolToString prod.system.disableInstallerTools}";
    }
    {
      name = "prod: no X server module, and nothing it would have switched on";
      # xrdp starts its own Xorg from sesman.ini; NixOS's X server module only
      # adds a greeter, an xsession script, input drivers for devices that do
      # not exist and a handful of X utilities.  Each of the three below is a
      # default that follows services.xserver.enable, which is why prod turns
      # off one option instead of four - and why they are asserted here.
      ok = !prod.services.xserver.enable
        && !prod.services.xserver.displayManager.lightdm.enable
        && !prod.services.displayManager.enable
        && !prod.gtk.iconCache.enable;
      detail = "xserver = ${lib.boolToString prod.services.xserver.enable}, "
        + "lightdm = ${lib.boolToString prod.services.xserver.displayManager.lightdm.enable}, "
        + "displayManager = ${lib.boolToString prod.services.displayManager.enable}, "
        + "gtk.iconCache = ${lib.boolToString prod.gtk.iconCache.enable}";
    }
    {
      name = "prod: documentation off, man-db included";
      # documentation.enable alone leaves man-db installed: its module keys off
      # documentation.man.enable on its own.
      ok = !prod.documentation.enable && !prod.documentation.man.enable;
      detail = "documentation.enable = ${lib.boolToString prod.documentation.enable}, "
        + "documentation.man.enable = ${lib.boolToString prod.documentation.man.enable}";
    }
    {
      name = "prod: no GPU driver stack";
      # ~770 MiB of Mesa and LLVM for llvmpipe, on a machine whose GPU does not
      # exist and whose only graphical application ships its own renderer.
      ok = !prod.hardware.graphics.enable;
      detail = "hardware.graphics.enable is on";
    }
    {
      name = "prod: the appliance Spotify, not the desktop one";
      # profiles/apps/spotify.nix swaps ffmpeg_4 for its headless build and
      # drops zenity; both together are worth ~330 MiB of closure.
      ok = spotifyOf prod != null
        && spotifyOf debug != null
        && (spotifyOf prod).drvPath != (spotifyOf debug).drvPath;
      detail = "prod and debug carry the same Spotify derivation";
    }
    {
      name = "prod: the trimmed openbox, not the one carrying a Python";
      # 52 MiB: nixpkgs wraps openbox-xdg-autostart with CPython and pyxdg, and
      # propagates pango's and imlib2's dev outputs into the runtime closure.
      # profiles/gui/openbox.nix removes both for production only, so the two
      # images must not share a derivation.
      ok = openboxOf prod != null
        && openboxOf debug != null
        && (openboxOf prod).drvPath != (openboxOf debug).drvPath;
      detail = "prod and debug carry the same openbox derivation";
    }
    {
      name = "prod: no desktop-session bits and no Perl activation";
      # services.graphical-desktop.enable installs xdg-utils, which is Perl,
      # which was the last thing holding perl in the image.  The three switches
      # below are nixpkgs' own perlless profile.
      ok = !prod.services.graphical-desktop.enable
        && prod.system.etc.overlay.enable
        && prod.services.userborn.enable
        && prod.boot.initrd.systemd.enable;
      detail = "graphical-desktop = ${lib.boolToString prod.services.graphical-desktop.enable}, "
        + "etc.overlay = ${lib.boolToString prod.system.etc.overlay.enable}, "
        + "userborn = ${lib.boolToString prod.services.userborn.enable}";
    }
    {
      name = "prod: the font set is chosen, not inherited";
      # The default set is DejaVu, FreeFont, Gyre, Liberation, Unifont and Noto
      # Color Emoji - 60 MiB.  This keeps the two that render what the kiosk
      # shows, and with the X server module off nothing else contributes to the
      # list, so the rule can name it exactly.  The core bitmap fonts that used
      # to arrive with that module are not missed: Xorg under xrdp never had a
      # FontPath and runs on libXfont2's built-in "fixed" and "cursor", which
      # tests/xrdp-session.nix asserts on a live session.
      ok =
        let names = map getName prod.fonts.packages;
        in !prod.fonts.enableDefaultPackages
          && lib.sort (a: b: a < b) names == [ "dejavu-fonts" "noto-fonts-color-emoji" ];
      detail = "fonts: ${concatStringsSep " " (map getName prod.fonts.packages)}";
    }
    {
      name = "prod: nothing broadcasts on the network";
      ok = !prod.services.avahi.enable;
      detail = "avahi is on, for a machine with a static address and static resolvers";
    }
    {
      name = "prod: the exorcised stay exorcised";
      # system.forbiddenDependenciesRegexes fails the build if any of these
      # comes back transitively, which a closure budget alone would not catch.
      ok = lib.all (r: lib.elem r prod.system.forbiddenDependenciesRegexes)
        [ "perl" "speech-dispatcher" "mbrola" "zenity" "xterm" ];
      detail = "forbiddenDependenciesRegexes = ${toString prod.system.forbiddenDependenciesRegexes}";
    }
    {
      name = "prod: no speech synthesizer";
      # ~700 MB of espeak-ng, flite and MBROLA voices, switched on for every
      # graphical NixOS system by services/misc/graphical-desktop.nix.
      ok = !prod.services.speechd.enable;
      detail = "services.speechd.enable is on in a music player";
    }
    {
      name = "prod: the boot loader is installed without Nix";
      # NixOS's systemd-boot installer is a Python script that calls
      # `nix-env --list-generations`, which is how an appliance with
      # nix.enable = false still shipped Nix, boost, the AWS SDK and libgit2.
      # profiles/modes/prod.nix installs the same systemd-boot from a shell
      # script through boot.loader.external instead.  Debug keeps the stock
      # builder, because nixos-rebuild inside the guest needs it.
      ok = prod.boot.loader.external.enable
        && !prod.boot.loader.systemd-boot.enable
        && !prod.boot.loader.grub.enable
        && debug.boot.loader.systemd-boot.enable;
      detail = "external = ${lib.boolToString prod.boot.loader.external.enable}, "
        + "systemd-boot = ${lib.boolToString prod.boot.loader.systemd-boot.enable}, "
        + "grub = ${lib.boolToString prod.boot.loader.grub.enable}, "
        + "debug systemd-boot = ${lib.boolToString debug.boot.loader.systemd-boot.enable}";
    }
    {
      name = "prod: nothing grows the root partition on every boot";
      # The upstream Hyper-V image turns boot.growPartition on for disks that
      # were enlarged after the image was written.  tools/qubixctl.ps1 has no
      # Resize-VHD: it downloads an image of a fixed size and replaces it.
      # autoResize stays, because it is the same safety net one layer up and
      # costs nothing.
      ok = !prod.boot.growPartition && prod.fileSystems."/".autoResize;
      detail = "growPartition = ${lib.boolToString prod.boot.growPartition}, "
        + "autoResize = ${lib.boolToString prod.fileSystems."/".autoResize}";
    }
    {
      name = "prod: no nixpkgs sources pinned into the system";
      # ~186 MB of Nix expressions, so that nix commands the appliance never
      # runs would resolve <nixpkgs> offline.
      ok = !prod.nixpkgs.flake.setFlakeRegistry && !prod.nixpkgs.flake.setNixPath;
      detail = "setFlakeRegistry = ${lib.boolToString prod.nixpkgs.flake.setFlakeRegistry}, "
        + "setNixPath = ${lib.boolToString prod.nixpkgs.flake.setNixPath}";
    }
    {
      name = "prod: no package manager, and no ssh client behind it";
      # nix-daemon carries an OpenSSH client on its PATH for remote builds,
      # which is how a sealed appliance ends up with one.
      ok = !prod.nix.enable
        && !(lib.any (n: n == "openssh") (names prod));
      detail = "nix.enable = ${lib.boolToString prod.nix.enable}";
    }
    {
      name = "prod: corePackages is an allowlist, not the interactive set";
      ok =
        let n = map getName prod.environment.corePackages;
        in !(lib.any (x: lib.elem x n) [ "openssh" "bind" "curl" "coreutils-full" ]);
      detail = "corePackages: ${concatStringsSep " " (map getName prod.environment.corePackages)}";
    }
    {
      name = "prod: no sshd";
      ok = !prod.services.openssh.enable;
      detail = "services.openssh.enable is on";
    }
    {
      name = "prod: the kiosk session is Spotify, not a bare window manager";
      ok = lib.hasSuffix "/bin/spotibox-session" prod.qubix.session.command;
      detail = "qubix.session.command = ${prod.qubix.session.command}";
    }

    {
      name = "debug: keeps the tools prod dropped";
      ok = lib.all (has debugNames) debugOnly;
      detail = "missing: ${concatStringsSep " " (filter (n: !has debugNames n) debugOnly)}";
    }
    {
      name = "debug: keeps a normal graphics stack";
      ok = debug.hardware.graphics.enable;
      detail = "hardware.graphics.enable is off in the debug image too, which "
        + "leaves nothing to compare a rendering problem against";
    }
    {
      name = "debug: keeps avahi and the stock font set";
      ok = debug.services.avahi.enable && debug.fonts.enableDefaultPackages;
      detail = "the debug image is supposed to stay a normal NixOS box";
    }
    {
      name = "debug: keeps the X server module and its greeter";
      # Production runs Xorg only through xrdp.  The debug image is the one
      # place a local console session can be compared against, so it keeps the
      # stock module - and LightDM with it, which is why the greeter in
      # profiles/gui/openbox.nix follows services.xserver.enable rather than
      # being asked for unconditionally.
      ok = debug.services.xserver.enable
        && debug.services.xserver.displayManager.lightdm.enable;
      detail = "xserver = ${lib.boolToString debug.services.xserver.enable}, "
        + "lightdm = ${lib.boolToString debug.services.xserver.displayManager.lightdm.enable}";
    }
    {
      name = "debug: keeps sshd";
      ok = debug.services.openssh.enable;
      detail = "services.openssh.enable is off in the debug image";
    }
  ];

  failures = filter (r: !r.ok) rules;

  report = concatMapStrings (r: "${if r.ok then "ok  " else "FAIL"}  ${r.name}\n") rules;
in

if failures != [ ] then
  throw ''
    spotibox appliance split violated:
    ${concatMapStrings (r: "  - ${r.name}\n      ${r.detail}\n") failures}
    profiles/modes/prod.nix decides what a production image is allowed to
    contain.  If the new package really belongs in the appliance, add it there
    and refresh the closure budget with tools/closure.sh baseline.
  ''
else
  pkgs.runCommand "spotibox-appliance-split" { passAsFile = [ "report" ]; inherit report; } ''
    cp "$reportPath" "$out"
  ''
