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
    machine.succeed("command -v pavucontrol")
    machine.succeed("systemctl is-enabled xrdp")
    machine.succeed("systemctl is-enabled avahi-daemon")

    # The xrdp session must be the Spotify kiosk session, not a bare WM.
    machine.succeed("grep -q spotibox-session /etc/xrdp/startwm.sh")
    machine.succeed("grep -q 'class=\"Spotify\"' /etc/qubix/openbox-rc.xml")
  '';
}
