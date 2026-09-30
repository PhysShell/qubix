{ pkgs }:

# RDP audio end to end, and again after a reconnect.
#
# tests/xrdp-session.nix starts a session with xrdp-sesrun, which is enough to
# prove the X server, the window manager and the kiosk come up - and proves
# nothing about sound, because sesrun is not an RDP client and never opens the
# audio channel.  This test is one: FreeRDP connects to the appliance's own
# xrdp, logs in as `rdp`, and asks for sound.  PulseAudio in the session then
# plays noise into its default sink, which the xrdp module makes module-xrdp-sink;
# xrdp-chansrv carries it over RDPSND; and the client logs each block it
# receives.  Its fake backend discards the audio, so the log is the evidence:
# a Wave PDU in PCM, the only format the xrdp in profiles/audio offers.
#
# Then the client goes away and comes back, which is where RDP audio has a
# habit of breaking: the session survives the disconnect, chansrv's socket
# does not, and the sink in the still-running PulseAudio has to find the new
# one.  The second connection has to receive audio as well.
#
# The driver runs every command under `set -euo pipefail`, which shapes the
# script: nothing here pipes into a reader that stops early (`grep -q`,
# `head`), because the writer then dies of SIGPIPE and fails the pipeline
# whatever the reader found.

let
  uidOf = "id -u rdp";
  pactl = "${pkgs.pulseaudio}/bin/pactl";
  pacat = "${pkgs.pulseaudio}/bin/pacat";
  # WLog writes to stdout, which is a file here and so block-buffered: a line
  # the test waits for could sit in the buffer for as long as the client has
  # nothing more to say.
  stdbuf = "${pkgs.coreutils}/bin/stdbuf -oL -eL";
in

pkgs.testers.nixosTest {
  name = "spotibox-xrdp-audio";

  nodes.machine = { lib, ... }: {
    imports = [ ../machines/spotibox.nix ];

    # Same as tests/xrdp-session.nix: no second disk, and room for Spotify,
    # which the kiosk session starts whether or not anything plays.
    qubix.homeDisk.enable = lib.mkForce false;
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("xrdp-sesman.service")
    machine.wait_for_unit("xrdp.service")

    # The client needs a display of its own; the appliance has no X server
    # outside xrdp sessions.
    machine.succeed("${pkgs.xorg.xvfb}/bin/Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &")
    machine.wait_for_file("/tmp/.X11-unix/X99")

    uid = machine.succeed("${uidOf}").strip()
    # xrdp 0.10 keeps a session's sockets in a directory per user.  chansrv
    # listens there for the sink while a client has sound, and stops listening
    # while a sink is connected, so the listing is a picture, not a check.
    sockdir = f"/run/xrdp/{uid}"

    def as_rdp(cmd):
        return f"su rdp -s /bin/sh -c 'XDG_RUNTIME_DIR=/run/user/{uid} {cmd}'"

    def pactl_says(subcommand, pattern):
        return as_rdp(f"${pactl} {subcommand}") + f" | grep -E '{pattern}' >/dev/null"

    def sink_running():
        return pactl_says("list sinks short", "xrdp-sink.*RUNNING")

    # Every command here runs as `timeout 900 bash -c '<command>'`, so a
    # pattern that matches whole command lines (pgrep -f) finds the command
    # looking for it.  The client is matched by process name instead.
    def client_gone():
        machine.succeed("${pkgs.procps}/bin/pkill -x xfreerdp")
        machine.wait_until_fails("${pkgs.procps}/bin/pgrep -x xfreerdp")

    def connect(n):
        machine.succeed(
            "DISPLAY=:99 ${stdbuf} ${pkgs.freerdp}/bin/xfreerdp /v:127.0.0.1 /u:rdp /p:1234 "
            "/cert:ignore /size:1280x800 /sound:sys:fake /log-level:INFO "
            "/log-filters:com.freerdp.channels.rdpsnd.client:DEBUG "
            f">/tmp/xfreerdp-{n}.log 2>&1 &"
        )
        # chansrv sends a client that asked for sound its formats and then a
        # training PDU.  That line in this connection's own log is what says
        # its channel is up - not chansrv's socket, which could be left over
        # from the connection before.
        machine.wait_until_succeeds(f"grep -q 'Training Request' /tmp/xfreerdp-{n}.log", timeout=600)
        print(machine.succeed(f"ls -l {sockdir}"))

    def plays(n):
        # Noise for half a minute into the session's default sink, and the
        # client has to log blocks of it arriving while it plays.
        machine.succeed(as_rdp("timeout 30 ${pacat} --format=s16le --rate=44100 --channels=2 < /dev/urandom") + " >/dev/null 2>&1 &")
        machine.wait_until_succeeds(sink_running(), timeout=60)
        machine.wait_until_succeeds(f"grep -q -E 'Wave2PDU|Wave: cBlockNo' /tmp/xfreerdp-{n}.log", timeout=120)
        log = machine.succeed(f"grep -m 5 -E 'WaveInfo|Wave2PDU|Opening device' /tmp/xfreerdp-{n}.log")
        print(log)
        assert "WAVE_FORMAT_PCM" in log, log
        machine.wait_until_fails(sink_running(), timeout=90)

    def diagnose():
        for cmd in [
            "tail -n 30 /tmp/xfreerdp-*.log",
            f"ls -la /run/xrdp {sockdir}",
            "tail -n 40 /home/rdp/.local/share/xrdp/*.log",
        ]:
            print(machine.execute(cmd)[1])

    try:
        connect(1)
        # The session's startup script loads the xrdp sink and makes it the
        # default, on its own schedule: until it has, a stream goes to the
        # null sink PulseAudio starts with.
        machine.wait_until_succeeds(pactl_says("info", "Default Sink: xrdp-sink"), timeout=120)
        plays(1)

        # Gone and back.  The session outlives the client; the audio has to
        # follow the new one.  The pause is xrdp's time to notice the first
        # client has gone, so the second is a reconnect and not a race.
        client_gone()
        machine.sleep(5)
        connect(2)
        plays(2)
    except Exception:
        diagnose()
        raise
  '';
}
