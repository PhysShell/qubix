# scanbox: a disposable, headless batch VM for running analysis jobs on
# untrusted third-party source code.
#
# Unlike spotibox this is not a Hyper-V appliance.  It runs under QEMU/KVM
# from WSL (or any Linux host with /dev/kvm) through the NixOS `build.vm`
# runner, so starting it needs no Windows administrator rights - which is the
# point: Hyper-V and Windows Sandbox both want an elevated token.
#
# One run is one job:
#   - the host passes a job directory (read-only to the guest, enforced by
#     QEMU with readonly=on, not just by a guest mount option) and an output
#     directory (read-write);
#   - the guest boots, runs /job/run.sh as the unprivileged `job` user, writes
#     its exit code to /out/exit-code and powers off;
#   - the system disk is thrown away by tools/scanbox-run.sh before every run.
#
# What the guest can see of the host: /job, /out and the host's /nix/store
# (shared read-only by the qemu-vm module; the store holds no secrets by
# construction).  No home directory, no Windows drives, no NuGet or MSBuild
# configuration, no credentials.
#
# Network: QEMU user-mode NAT, so a job can fetch sources and packages.  The
# NAT gateway 10.0.2.2 is the host itself, and under WSL's mirrored
# networking the host's loopback services sit behind it, so the guest firewall
# drops traffic to it and to private ranges.  That rule is enforced by the
# guest kernel; the job user cannot change it, a root compromise of the guest
# could.  Good enough for parsing code, not for executing hostile binaries.
{ lib, pkgs, ... }:

let
  jobPackages = with pkgs; [
    bashInteractive
    dotnet-sdk_8
    git
    python312
    gnutar
    gzip
    coreutils
    findutils
    gnugrep
    gnused
    curl
    cacert
    jq
  ];
in
{
  system.stateVersion = "25.11";
  networking.hostName = "scanbox";
  time.timeZone = "UTC";
  documentation.enable = false;

  virtualisation = {
    memorySize = 6144;
    cores = 4;
    diskSize = 16 * 1024;
    graphics = false;

    # /job (ro) and /out (rw) come from the environment of the run script, so
    # one built VM serves any number of jobs.  sharedDirectories cannot say
    # readonly=on, so the shares are spelled out as -virtfs options.
    qemu.options = [
      "-virtfs local,path=\"$QUBIX_JOB\",security_model=none,mount_tag=job,readonly=on"
      "-virtfs local,path=\"$QUBIX_OUT\",security_model=none,mount_tag=out"
    ];
    fileSystems = {
      "/job" = {
        device = "job";
        fsType = "9p";
        options = [ "trans=virtio" "version=9p2000.L" "ro" "msize=1048576" ];
      };
      "/out" = {
        device = "out";
        fsType = "9p";
        options = [ "trans=virtio" "version=9p2000.L" "msize=1048576" ];
      };
    };
  };

  # No accounts anyone logs into.  The console autologin the qemu-vm module
  # would offer is disabled; the job runs as a service.
  users.mutableUsers = false;
  # Deliberate: nobody logs into a job VM; its disk is discarded after one run.
  users.allowNoPasswordLogin = true;
  # 9p with security_model=none shows the guest the host's numeric owners, so
  # the job user takes uid 1000 - the usual owner of a WSL user's files - to be
  # able to write /out.  No password, no wheel, no shell anyone logs into.
  users.users.job = {
    isNormalUser = true;
    uid = 1000;
    group = "users";
    home = "/var/lib/job";
    createHome = true;
  };
  services.getty.autologinUser = lib.mkForce null;

  services.openssh.enable = false;

  networking.firewall.enable = true;
  networking.nftables.enable = true;
  networking.nftables.tables.scanbox-egress = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority 0; policy accept;
        oifname "lo" accept
        ip daddr 10.0.2.3 udp dport 53 accept
        ip daddr 10.0.2.3 tcp dport 53 accept
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 } drop
        ip6 daddr { fc00::/7, fe80::/10 } drop
      }
    '';
  };

  environment.systemPackages = jobPackages;

  systemd.services.scanbox-job = {
    description = "Run /job/run.sh once, then power off";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "job.mount" "out.mount" ];
    path = jobPackages;
    environment = {
      HOME = "/var/lib/job";
      DOTNET_CLI_TELEMETRY_OPTOUT = "1";
      DOTNET_NOLOGO = "1";
      DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      PYTHONUTF8 = "1";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "job";
      Group = "users";
      WorkingDirectory = "/var/lib/job";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      # The job's own exit code goes to /out; the unit always succeeds so that
      # ExecStopPost powers the machine off either way.
      ExecStart = pkgs.writeShellScript "scanbox-job" ''
        set -u
        echo "scanbox: job start $(date -u +%FT%TZ)" | tee /out/scanbox.log
        if [ -x /job/run.sh ] || [ -f /job/run.sh ]; then
          bash /job/run.sh 2>&1 | tee -a /out/scanbox.log
          rc=''${PIPESTATUS[0]}
        else
          echo "scanbox: /job/run.sh not found" | tee -a /out/scanbox.log
          rc=127
        fi
        echo "$rc" > /out/exit-code
        echo "scanbox: job end rc=$rc $(date -u +%FT%TZ)" | tee -a /out/scanbox.log
      '';
      ExecStopPost = "+${pkgs.systemd}/bin/systemctl poweroff --no-block";
    };
  };
}
