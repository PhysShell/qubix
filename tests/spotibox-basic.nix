{ pkgs }:

pkgs.testers.nixosTest {
  name = "spotibox-basic";

  nodes.machine = {
    imports = [
      ../machines/spotibox.nix
    ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    machine.succeed("test $(hostname) = spotibox")
    machine.succeed("id user")
    machine.succeed("id rdp")
    machine.succeed("command -v spotify")
    machine.succeed("command -v openbox-session")
    machine.succeed("command -v pavucontrol")
    machine.succeed("systemctl is-enabled xrdp")
    machine.succeed("systemctl is-enabled avahi-daemon")
    machine.succeed("test -f /etc/xdg/openbox/autostart")
    machine.succeed("grep -q spotify /etc/xdg/openbox/autostart")
  '';
}
