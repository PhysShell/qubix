{ config, lib, pkgs, ... }:

let
  kb = config.qubix.keyboard;

  setxkbmap = "${pkgs.xorg.setxkbmap}/bin/setxkbmap";
  awk = "${pkgs.gawk}/bin/awk";

  # xrdp pins the guest's XKB layout to whatever the client had at connect time
  # and never revisits it: RDP carries the layout once, in the Client Info PDU,
  # and sends bare scancodes from then on.  Switching the layout on the Windows
  # side therefore changes nothing in the guest until you reconnect.
  #
  # Two things make this awkward to fix from startwm.sh:
  #
  #   * X is not necessarily accepting connections yet when startwm.sh runs, so
  #     a single setxkbmap call can silently do nothing;
  #   * xrdp may apply the client's layout *after* the session script starts,
  #     overwriting whatever was set.
  #
  # So run in the background and keep checking for a while, re-applying if the
  # toggle disappeared.  Failures go to stderr (and thus the session log) rather
  # than being swallowed, which is how the first version of this hid its own
  # breakage.
  session = pkgs.writeShellScript "qubix-xrdp-session" ''
    (
      attempts=12
      while [ "$attempts" -gt 0 ]; do
        attempts=$((attempts - 1))
        sleep 1

        query=$(${setxkbmap} -query 2>/dev/null) || continue

        # Already carrying our toggle: nothing to do this round.
        case "$query" in
          *${kb.toggle}*) continue ;;
        esac

        wanted='${kb.layouts}'
        if [ -z "$wanted" ]; then
          # Client-agnostic default: keep the negotiated layout and put a Latin
          # group next to it, so shell commands stay typable either way.
          current=$(printf '%s\n' "$query" | ${awk} '/^layout:/ { print $2 }')
          case "$current" in
            "" | ${kb.latinGroup} | ${kb.latinGroup},*) wanted="$current" ;;
            *) wanted="${kb.latinGroup},$current" ;;
          esac
          [ -n "$wanted" ] || wanted='${kb.latinGroup}'
        fi

        if ! ${setxkbmap} -layout "$wanted" -option "" -option '${kb.toggle}'; then
          echo "qubix: setxkbmap -layout $wanted failed" >&2
        fi
      done
    ) &

    exec ${config.qubix.session.command}
  '';
in
{
  # xrdp is the appliance's window to the Windows host.  Whatever the active
  # profiles put into qubix.session.command becomes the session: a plain
  # window manager for generic images, or a single-app kiosk session such as
  # Spotify.  When that command exits, xrdp ends the session and mstsc closes.
  #
  # The session is wrapped so keyboard groups are fixed up alongside it; see
  # above.  services.xserver.xkb.options is deliberately NOT forwarded: its
  # NixOS default is terminate:ctrl_alt_bksp, which xrdp never applies on its
  # own, and arming it would let a stray keypress kill the kiosk session.
  services.xrdp = {
    enable = true;
    defaultWindowManager = "${session}";
    openFirewall = true;
  };
}
