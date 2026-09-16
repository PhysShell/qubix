{ pkgs }:

pkgs.testers.nixosTest {
  name = "spotibox-basic";

  nodes.machine = { lib, ... }: {
    imports = [
      ../machines/spotibox.nix
    ];

    # The test VM has no second disk, and the persistent-home profile makes
    # boot wait for one.  Keep the test on a single disk; the home-disk
    # contract is exercised by the real Hyper-V VM.
    qubix.homeDisk.enable = lib.mkForce false;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    machine.succeed("test $(hostname) = spotibox")
    machine.succeed("test $(id -u user) = 1000")
    machine.succeed("test $(id -u rdp) = 1001")
    machine.succeed("command -v spotify")
    machine.succeed("command -v openbox-session")
    machine.succeed("systemctl is-enabled xrdp")

    # /etc is an overlayfs and the users were created by userborn: both come
    # from dropping the Perl activation scripts.
    machine.succeed("findmnt -no FSTYPE /etc | grep -q overlay")
    machine.succeed("systemctl show -p Result userborn.service | grep -q success")

    # The xrdp session must be the Spotify kiosk session, not a bare WM.  What
    # startwm.sh names is the keyboard wrapper from profiles/remote/xrdp.nix,
    # and the wrapper is what execs the kiosk session, so the check has to
    # follow both links - grepping startwm.sh for the session name alone
    # silently stopped meaning anything when the wrapper was introduced.
    wrapper = machine.succeed(
        "grep -o '/nix/store/[^ ]*-qubix-xrdp-session' /etc/xrdp/startwm.sh"
    ).strip()
    machine.succeed(f"grep -q spotibox-session {wrapper}")
    machine.succeed("grep -q 'class=\"Spotify\"' /etc/qubix/openbox-rc.xml")

    # This is a production image: everything that only exists to debug the
    # appliance has to be missing from it, because anything still present is
    # also still in the closure.  The debug image keeps all of it; see
    # tests/appliance-split.nix for the evaluation-level version of this.
    machine.fail("command -v xterm")
    machine.fail("command -v pavucontrol")
    machine.fail("command -v alsamixer")
    machine.fail("command -v strace")
    machine.fail("command -v nixos-rebuild")
    machine.fail("command -v man")

    # The kiosk session comes from xrdp; nothing greets anybody locally.
    machine.fail("systemctl is-enabled display-manager.service")

    # Nothing announces itself on a network with a static address.
    machine.fail("systemctl is-enabled avahi-daemon")
  '';
}
