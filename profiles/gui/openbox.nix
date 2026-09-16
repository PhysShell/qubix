{ config, lib, pkgs, ... }:

let
  debug = config.qubix.mode == "debug";
in
lib.mkIf (config.qubix.gui == "openbox") {
  # Openbox looks like the one package here that nobody needs to argue about:
  # 1.5 MiB, a window manager and nothing else.  Its closure is 302 MiB, and
  # 52 MiB of that is reachable from no code path this appliance can execute.
  # Two separate reasons, both visible in pkgs/by-name/op/openbox/package.nix:
  #
  #   * `pythonPath = [ pyxdg ]` and `wrapPythonProgramsIn "$out/libexec"` put
  #     a wrapped CPython on `libexec/openbox-xdg-autostart`, which exists to
  #     launch XDG autostart entries.  It is called from one place,
  #     `libexec/openbox-autostart`, which is called from `openbox-session`.
  #     The kiosk session runs `openbox` directly and production forces
  #     `xdg.autostart.enable` off, so nothing in this image reaches it.
  #   * `propagatedBuildInputs = [ pango imlib2 ]` writes their *dev* outputs
  #     into `nix-support/propagated-build-inputs`, and Nix scans that file for
  #     references like any other.  So the runtime closure of a window manager
  #     contains pango-dev, imlib2-dev and, behind them, glib-dev, gettext,
  #     the Linux kernel headers and a dozen more `-dev` outputs - 50 MiB of
  #     build-time metadata in an appliance that compiles nothing.
  #
  # An overlay rather than a package option: the upstream window-manager module
  # has no `package` option and interpolates `pkgs.openbox` directly, and so do
  # the session command below and the kiosk session in profiles/apps/spotify.nix.
  # Debug images keep the stock package, as they keep everything else.
  #
  # The interpreter itself does not leave the image with this - systemd-boot's
  # installer, `lsvmbus` from hyperv-daemons and growpart each hold their own
  # reference to it - but pyxdg, packaging and the whole -dev tail do.
  nixpkgs.overlays = lib.optionals (!debug) [
    (_final: prev: {
      openbox = prev.openbox.overrideAttrs (old: {
        postFixup = (old.postFixup or "") + ''
          rm -f "$out/libexec/openbox-xdg-autostart" \
                "$out/libexec/.openbox-xdg-autostart-wrapped"

          # The helper is invoked from exactly one line, and --replace-fail is
          # the guard: if upstream ever moves the call, this stops being a
          # silent no-op.  The trailing marker swallows the "$@" after it.
          substituteInPlace "$out/libexec/openbox-autostart" \
            --replace-fail "$out/libexec/openbox-xdg-autostart" \
                           "# xdg autostart removed, see profiles/gui/openbox.nix --"

          rm -rf "$out/nix-support"

          # If nixpkgs ever wraps another helper in here, fail the build rather
          # than quietly putting an interpreter back into the appliance.
          if grep -rl --binary-files=text -e '-python3-' "$out"; then
            echo "openbox still references a Python interpreter (above)" >&2
            exit 1
          fi
        '';
      });
    })
  ];

  # Minimal X11 desktop stack.  Openbox is enough to host Spotify and, on debug
  # images, an emergency terminal, without dragging a full desktop environment
  # into the appliance.  openbox itself reaches systemPackages through
  # services.xserver.windowManager.openbox.enable, which is a module of its own
  # and does not depend on services.xserver.enable - which matters, because
  # production forces the X server module off entirely and lets xrdp start Xorg
  # on its own terms.  See profiles/modes/prod.nix for what that costs and what
  # it saves; debug images keep the stock module and the greeter below.
  services.xserver.enable = true;
  services.xserver.windowManager.openbox.enable = true;

  # A greeter is only useful on an image somebody logs into locally, and it is
  # the X server module that would run it.  Production forces that module off,
  # and LightDM asserts that it is on, so the greeter has to follow the module
  # rather than be switched off a second time next to it.
  services.xserver.displayManager.lightdm.enable =
    lib.mkDefault config.services.xserver.enable;

  # Remote sessions get a bare Openbox unless an app profile overrides this.
  qubix.session.command = lib.mkDefault "${pkgs.openbox}/bin/openbox-session";

  # The emergency terminal is a debugging tool, not part of the product: in the
  # kiosk session Spotify covers the root window, so the Openbox menu that would
  # launch it is unreachable anyway.  There used to be a
  # services.xserver.excludePackages entry here, because NixOS's X server module
  # installs xterm whether or not anybody asked for it; production no longer
  # evaluates that module at all, so the exclusion had nothing left to exclude.
  # system.forbiddenDependenciesRegexes in profiles/modes/prod.nix is what keeps
  # xterm from coming back by another route.

  # xterm's compiled-in default is the bitmap "fixed" font in ISO-8859-1, which
  # carries no Cyrillic (or any non-latin) glyphs, so typing Russian over RDP
  # renders as boxes even though 75 Cyrillic-capable fonts are installed and the
  # locale is UTF-8.  Normally X resources would fix this, but nothing in this
  # image loads them: there is no display manager session and no xrdb call, and
  # ~/.Xresources would live on the persistent home disk rather than in Nix.
  # So the defaults are baked into the binary the Openbox menu actually invokes.
  environment.systemPackages = lib.optionals debug (with pkgs; [
    (lib.hiPrio (writeShellScriptBin "xterm" ''
      exec ${xterm}/bin/xterm -fa 'DejaVu Sans Mono' -fs 11 -u8 "$@"
    ''))
    xterm
  ]);
}
