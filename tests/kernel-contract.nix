{ pkgs, lib, prod, debug }:

# What the appliance's kernel must and must not contain.
#
# A closure budget notices that the kernel got bigger.  It does not notice that
# the reason it got smaller was `overlayfs`, which is the filesystem /etc is
# mounted from since profiles/modes/prod.nix went perlless - so the image would
# stop booting long before anyone read a size report.
#
# This reads the finished `.config`, which is the only place the whole contract
# is visible: half of it is guaranteed by nixpkgs' common-config.nix, half by
# profiles/kernel/hyperv.nix, and neither file on its own is the answer.
# Reading the config is cheap - it is produced by the kernel's configure phase,
# not by compiling it - so this runs in `nix flake check` with everything else.
#
# The `absent` list is deliberately short.  Writing one line per Kconfig symbol
# is how you end up maintaining a second copy of Linux; these are the handful
# of decisions somebody would have to argue with, not an inventory.

let
  inherit (lib) concatMapStrings concatStringsSep;

  # Required: every one of these is something this image has been observed to
  # use, with where it was observed.
  required = {
    # Hyper-V.  The bus and the only four devices this machine has.
    HYPERV = "the VMBus itself";
    HYPERV_STORAGE = "the root disk and the home disk";
    HYPERV_NET = "the only NIC";
    HYPERV_KEYBOARD = "the console keyboard";
    HYPERV_UTILS = "host-requested shutdown, timesync and heartbeat";
    HYPERV_BALLOON = "Dynamic Memory";
    DRM_HYPERV = "the console Hyper-V Manager shows";

    # The boot path, in the order the firmware walks it.
    EFI_STUB = "the kernel is loaded by systemd-boot as an EFI binary";
    EFI_PARTITION = "the GPT the image is partitioned with";
    VFAT_FS = "the ESP";
    EXT4_FS = "the root filesystem and the home disk";
    BLK_DEV_SD = "how the synthetic SCSI disks appear";
    BLK_DEV_DM = "device-mapper, kept for the dm-verity image in TODO";

    # boot.initrd.systemd names these in the initrd's module list whether or
    # not the machine has a TPM, and a module name that does not resolve fails
    # the modules-shrunk build rather than warning.  That is how this file
    # earns its keep: the failure otherwise arrives 40 minutes into a kernel
    # compile, as `FATAL: Module hid_corsair not found`.
    TCG_TIS = "boot.initrd.systemd asks for tpm-tis";
    TCG_CRB = "boot.initrd.systemd asks for tpm-crb";

    # Not optional since the image went perlless: system.etc.overlay mounts an
    # erofs metadata image and an overlayfs on top of it, so without either of
    # these there is no /etc at all.
    OVERLAY_FS = "system.etc.overlay - /etc is an overlay mount";
    EROFS_FS = "system.etc.overlay - /run/nixos-etc-metadata is erofs";

    FUSE_FS = "systemd mounts /sys/fs/fuse/connections on start";
    AUTOFS_FS = "systemd's automounts";
    DEVTMPFS_MOUNT = "/dev before userspace exists";
    TMPFS_XATTR = "systemd wants xattrs on /run";

    # The firewall, which is what keeps 3389 the only way in.
    NF_TABLES = "networking.firewall - NixOS's iptables is iptables-nft";
    NFT_COMPAT = "the same, one layer down";
    NF_CONNTRACK = "the firewall's established/related rule";
    NETFILTER_XT_MATCH_CONNTRACK = "the same rule, the match itself";

    # What the tests run on.  A kernel that only boots on Hyper-V cannot be
    # checked before it ships, so QEMU is part of the contract on purpose:
    # the NixOS VM tests use virtio and a 9p store, tools/cold-boot.sh
    # attaches the image to an AHCI port.
    # This is the whole of nixos/modules/profiles/qemu-guest.nix, which every
    # NixOS VM test imports.  It is listed in full and not by sampling,
    # because each of these names is a hard build failure when it does not
    # resolve - and the failure lands in modules-shrunk, 40 minutes into a
    # kernel compile, reading `FATAL: Module virtio_mmio not found`.
    VIRTIO_PCI = "profiles/qemu-guest.nix";
    VIRTIO_MMIO = "profiles/qemu-guest.nix";
    VIRTIO_BLK = "profiles/qemu-guest.nix";
    SCSI_VIRTIO = "profiles/qemu-guest.nix - virtio_scsi";
    VIRTIO_NET = "profiles/qemu-guest.nix";
    VIRTIO_CONSOLE = "profiles/qemu-guest.nix";
    VIRTIO_BALLOON = "profiles/qemu-guest.nix";
    HW_RANDOM_VIRTIO = "profiles/qemu-guest.nix - virtio_rng";
    DRM_VIRTIO_GPU = "profiles/qemu-guest.nix - virtio_gpu";
    NET_9P = "profiles/qemu-guest.nix - the store is mounted over 9p";
    "9P_FS" = "the store is mounted over 9p, filesystem end";

    # Dynamic Memory: hv_balloon hands the guest new memory blocks, the udev
    # rules copied into profiles/modes/prod.nix online them, and neither works
    # without this.  Inherited from the architecture default rather than set
    # here, which is exactly why it is worth asserting.
    MEMORY_HOTPLUG = "Hyper-V Dynamic Memory";
    MEMORY_HOTREMOVE = "Hyper-V Dynamic Memory, the other direction";
    NET_9P_VIRTIO = "profiles/qemu-guest.nix";
    SATA_AHCI = "tools/cold-boot.sh attaches the VHDX to an AHCI port";
  };

  # Absent: hardware or subsystems this machine cannot have.  One line each,
  # and each one has to be a decision somebody could argue with - this is a
  # list of arguments, not an inventory of Kconfig.
  absent = {
    # The one that looks wrong and is not.  This appliance plays music, but
    # never through a sound card: mstsc negotiates audio over RDP,
    # xrdp-chansrv hands it to PulseAudio over a unix socket, and
    # module-xrdp-sink opens no device.  Checked on a running kiosk with
    # Spotify up: /proc/asound does not exist and no snd module is loaded.
    SOUND = "audio goes over RDP, not through a sound card";
    SND = "the same, one layer down";

    # No radios, and nothing to switch them off with.
    WLAN = "a virtual machine has no wireless card";
    CFG80211 = "the stack behind the card it does not have";
    MAC80211 = "and the layer behind that";
    BT = "no Bluetooth controller on a VMBus";
    NFC = "no NFC reader either";
    CAN = "no CAN bus in a music player";
    HAMRADIO = "nixpkgs turns this on for desktops; this is not one";

    # No capture hardware, no infrared remote.
    MEDIA_SUPPORT = "no webcam, no tuner, no capture card";
    RC_CORE = "nixpkgs turns it on for desktops with IR receivers";

    # Every driver for a physical GPU.  The DRM core stays - DRM_HYPERV is the
    # console and is required above - but x86_64's default config builds i915
    # into the kernel, on a machine Hyper-V gives no GPU to at all.
    DRM_I915 = "no Intel GPU";
    DRM_AMDGPU = "no AMD GPU";
    DRM_RADEON = "no Radeon";
    DRM_NOUVEAU = "no NVIDIA";

    # Buses a synthetic machine does not have.
    FIREWIRE = "no FireWire";
    THUNDERBOLT = "no Thunderbolt";
    INFINIBAND = "no InfiniBand";
    PARPORT = "no parallel port";
    BLK_DEV_FD = "no floppy drive";

    # Every driver for a physical NIC.  This machine's is hv_netvsc and the
    # test VMs' is virtio_net; neither is under this menu.
    ETHERNET = "no physical network card";

    # This appliance is a guest.  It does not host anything.
    VIRTUALIZATION = "nothing runs virtual machines inside the appliance";

    # Filesystems with no mount point here.  ext4, vfat, erofs, overlay and 9p
    # are required above; this is the rest of the menu.
    XFS_FS = "nothing is formatted xfs";
    BTRFS_FS = "nothing is formatted btrfs";
    NFS_FS = "nothing is mounted over NFS";
    CIFS = "nothing is mounted over SMB";

    ANDROID_BINDER_IPC = "Android's IPC layer, in a music player";
  };

  configOf = cfg: cfg.boot.kernelPackages.kernel.configfile;

  check = pkgs.runCommand "spotibox-kernel-contract"
    {
      config = configOf prod;
      debugConfig = configOf debug;
      passAsFile = [ "requiredList" "absentList" ];
      requiredList = concatStringsSep "\n"
        (lib.mapAttrsToList (k: why: "${k}\t${why}") required);
      absentList = concatStringsSep "\n"
        (lib.mapAttrsToList (k: why: "${k}\t${why}") absent);
    }
    ''
      fail=0
      report=""

      # `|| [ -n "$sym" ]`: concatStringsSep leaves no trailing newline, and
      # without this the loop silently skips the last entry - which it did,
      # for VIRTIO_PCI, until the report was counted against the list.
      while IFS=$'\t' read -r sym why || [ -n "$sym" ]; do
        [ -n "$sym" ] || continue
        if grep -qE "^CONFIG_$sym=(y|m)$" "$config"; then
          report="$report"$'\n'"ok    $sym"
        else
          report="$report"$'\n'"FAIL  $sym is not set - $why"
          fail=1
        fi
      done < "$requiredListPath"

      while IFS=$'\t' read -r sym why || [ -n "$sym" ]; do
        [ -n "$sym" ] || continue
        if grep -qE "^CONFIG_$sym=(y|m)$" "$config"; then
          report="$report"$'\n'"FAIL  $sym is set, and should not be - $why"
          fail=1
        else
          report="$report"$'\n'"ok    $sym absent"
        fi
      done < "$absentListPath"

      # The debug image is the comparison baseline; it must not quietly follow
      # production onto the trimmed kernel.
      if [ "$config" = "$debugConfig" ]; then
        report="$report"$'\n'"FAIL  the debug image is using the appliance kernel"
        fail=1
      else
        report="$report"$'\n'"ok    debug keeps nixpkgs' distribution kernel"
      fi

      # Belt and braces: the report has to account for every line of both
      # lists, or something ate an entry on the way through.
      # `|| true`: grep -c exits non-zero on an empty file, and the absent
      # list starts out empty.
      want=$(( $(grep -c . "$requiredListPath" || true) \
             + $(grep -c . "$absentListPath" || true) + 1 ))
      got=$(printf '%s\n' "$report" | grep -c .)
      if [ "$got" != "$want" ]; then
        echo "kernel contract: checked $got items, list has $want" >&2
        fail=1
      fi

      printf '%s\n' "$report" > "$out"
      if [ "$fail" != 0 ]; then
        cat "$out" >&2
        echo >&2
        echo "profiles/kernel/hyperv.nix decides what the appliance kernel contains." >&2
        exit 1
      fi
    '';
in
check
