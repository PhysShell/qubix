{ config, lib, pkgs, ... }:

let
  kb = config.qubix.keyboard;

  # xrdp pins the guest's XKB layout to whatever the client had at connect time
  # and never revisits it: RDP carries the layout once, in the Client Info PDU,
  # and sends bare scancodes from then on.  Switching the layout on the Windows
  # side therefore changes nothing in the guest until you reconnect, which is
  # exactly what it looks like from the user's chair.
  #
  # Hardcoding a layout list here would tie the image to one person's keyboard.
  # Instead, take whatever xrdp negotiated with *this* client and keep a Latin
  # group alongside it, plus a toggle: a German client gets "us,de", a Russian
  # one "us,ru", and a Latin-only client keeps its single group untouched.
  session = pkgs.writeShellScript "qubix-xrdp-session" ''
    layout=$(${pkgs.xorg.setxkbmap}/bin/setxkbmap -query \
      | ${pkgs.gawk}/bin/awk '/^layout:/ { print $2 }')
    case "$layout" in
      "" | ${kb.latinGroup} | ${kb.latinGroup},*) : ;;
      *) layout="${kb.latinGroup},$layout" ;;
    esac
    ${pkgs.xorg.setxkbmap}/bin/setxkbmap \
      -layout "''${layout:-${kb.latinGroup}}" \
      -option "" \
      -option "${config.services.xserver.xkb.options}" \
      -option "${kb.toggle}" || true

    exec ${config.qubix.session.command}
  '';
in
{
  # xrdp is the appliance's window to the Windows host.  Whatever the active
  # profiles put into qubix.session.command becomes the session: a plain
  # window manager for generic images, or a single-app kiosk session such as
  # Spotify.  When that command exits, xrdp ends the session and mstsc closes.
  #
  # The session is wrapped so keyboard groups are fixed up first; see above.
  services.xrdp = {
    enable = true;
    defaultWindowManager = "${session}";
    openFirewall = true;
  };
}
