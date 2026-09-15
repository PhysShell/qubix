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
# Runtime behaviour (the kiosk session, xrdp, the Openbox rules) is covered by
# tests/spotibox-basic.nix, which boots an actual VM.  The one property that
# needs the image derivation rather than the config — that no nixpkgs channel
# is copied into the production VHDX — is checked by `tools/closure.sh check`.

let
  inherit (lib) concatMapStrings concatStringsSep filter getName;

  # environment.systemPackages is the list NixOS turns into
  # /run/current-system/sw, and config/system-path.nix folds
  # environment.defaultPackages into it, so this one list covers both.
  names = cfg: map getName cfg.environment.systemPackages;

  prodNames = names prod;
  debugNames = names debug;

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
      name = "prod: no display manager, and no session plumbing around it";
      ok = !prod.services.xserver.displayManager.lightdm.enable
        && !prod.services.displayManager.enable;
      detail = "the kiosk session comes from xrdp, not from a greeter or an "
        + "xsession script; services.xserver.enable turns both of these on by "
        + "itself, so both have to be forced back off";
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
      name = "prod: no speech synthesizer";
      # ~700 MB of espeak-ng, flite and MBROLA voices, switched on for every
      # graphical NixOS system by services/misc/graphical-desktop.nix.
      ok = !prod.services.speechd.enable;
      detail = "services.speechd.enable is on in a music player";
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
