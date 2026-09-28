{ pkgs }:

# Boots the production appliance and asks xrdp for a real session.
#
# tests/spotibox-basic.nix checks what the image *contains*; this checks that
# the one thing it exists to do still works.  That distinction stopped being
# academic when profiles/modes/prod.nix turned `services.xserver.enable` off:
# the X server under xrdp is started by xrdp-sesman from its own sesman.ini,
# not by NixOS, and nothing short of starting a session proves that the pieces
# NixOS stopped providing were not needed.
#
# xrdp-sesrun is xrdp's own session starter - it speaks SCP to sesman exactly
# as the RDP listener does, so this exercises PAM, the Xorg command line baked
# into sesman.ini, startwm.sh, the keyboard wrapper from
# profiles/remote/xrdp.nix and the kiosk session, without an RDP client.  Its
# -p flag is documented upstream as "TESTING ONLY"; the password here is the
# disposable lab password that is already in the repository.
#
# The X clients below run as `rdp` with the session's own Xauthority: sesman
# starts Xorg with -auth, so root cannot open the display and a check that
# forgets this fails for the wrong reason.

let
  # Openbox publishes the windows it manages in _NET_CLIENT_LIST; Spotify also
  # keeps unmanaged 10x10 helper windows around from the moment it starts, so
  # matching on the class alone finds one of those long before the real UI
  # exists.  This looks for a managed client that is both Spotify and maximised
  # - which is the Openbox rule in profiles/apps/spotify.nix having fired - and
  # prints its window id.
  kioskWindow = pkgs.writeShellScript "kiosk-window" ''
    set -eu
    xprop=${pkgs.xorg.xprop}/bin/xprop
    list=$("$xprop" -root _NET_CLIENT_LIST)
    case "$list" in *"# "*) ;; *) exit 1 ;; esac
    for id in $(printf '%s' "''${list#*# }" | tr -d ' ' | tr ',' ' '); do
      state=$("$xprop" -id "$id" WM_CLASS _NET_WM_STATE)
      case "$state" in
        *'"Spotify"'*_NET_WM_STATE_MAXIMIZED_VERT*) ;;
        *) continue ;;
      esac
      case "$state" in *_NET_WM_STATE_MAXIMIZED_HORZ*) ;; *) continue ;; esac
      echo "$id"
      exit 0
    done
    exit 1
  '';
in

pkgs.testers.nixosTest {
  name = "spotibox-xrdp-session";

  nodes.machine = { lib, ... }: {
    imports = [ ../machines/spotibox.nix ];

    # Same reason as in tests/spotibox-basic.nix: no second disk here.
    qubix.homeDisk.enable = lib.mkForce false;

    # Spotify is a Chromium; the test default of 1 core and 1 GiB is not
    # enough for it to reach the point of mapping a window.
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("xrdp-sesman.service")
    # Not wait_for_open_port: that needs nc in the guest, and
    # environment.corePackages in the production image is an allowlist.
    machine.wait_for_unit("xrdp.service")

    out = machine.succeed(
        "${pkgs.xrdp}/bin/xrdp-sesrun -c /etc/xrdp/sesman.ini "
        "-g 1280x800 -p 1234 rdp 2>&1"
    )
    print(out)
    display = ":" + out.split("display=:")[1].split()[0].strip()

    def in_session(cmd):
        return (
            "su rdp -s /bin/sh -c "
            f"'XAUTHORITY=/home/rdp/.Xauthority DISPLAY={display} {cmd}'"
        )

    # The X server xrdp started is alive and talking.
    machine.wait_until_succeeds(in_session("${pkgs.xorg.xdpyinfo}/bin/xdpyinfo > /dev/null"), timeout=120)

    # Nothing sets a FontPath here - not NixOS, whose X server module is off,
    # and not xorgxrdp's xorg.conf - so the server falls back to the "built-ins"
    # font path element compiled into libXfont2.  That is the whole reason
    # dropping font-misc-misc, font-cursor-misc and font-alias with the module
    # costs nothing: they were never on this path to begin with.  If a font
    # package ever appears here, something is paying for core fonts again.
    path = machine.succeed(in_session("${pkgs.xorg.xset}/bin/xset q"))
    fp = path.split("Font Path:")[1].split("\n")[1].strip()
    assert fp == "built-ins", fp

    # And the two fonts the server itself needs open out of it: "cursor" for
    # the root cursor, "fixed" for anything that asks for the default font.
    fonts = machine.succeed(in_session("${pkgs.xorg.xlsfonts}/bin/xlsfonts")).split()
    assert "cursor" in fonts and "fixed" in fonts, fonts

    # profiles/remote/xrdp.nix re-applies the layout for up to twelve seconds
    # after the session starts, because xrdp may overwrite it.
    machine.wait_until_succeeds(
        in_session("${pkgs.xorg.setxkbmap}/bin/setxkbmap -query | grep -q grp:win_space_toggle"),
        timeout=120,
    )
    q = machine.succeed(in_session("${pkgs.xorg.setxkbmap}/bin/setxkbmap -query"))
    print(q)
    assert "us,ru" in q, q

    # Openbox has to own the display, or nothing gets maximised.
    machine.wait_until_succeeds(
        in_session("${pkgs.xorg.xprop}/bin/xprop -root _NET_SUPPORTING_WM_CHECK | grep -q \"window id\""),
        timeout=120,
    )

    # And the kiosk window itself: a managed client, maximised by the Openbox
    # rule in profiles/apps/spotify.nix rather than floating at its default
    # size.  Spotify is a Chromium and this VM has no KVM, so it gets a long
    # rope: everything before this point takes about two minutes, and the
    # window is the slow part.
    win = machine.wait_until_succeeds(in_session("${kioskWindow}"), timeout=900).strip()
    print(machine.succeed(in_session(f"${pkgs.xorg.xwininfo}/bin/xwininfo -id {win}")))
  '';
}
