{ config, lib, pkgs, ... }:

# A kernel built for one machine: a Hyper-V generation 2 guest.
#
# `pkgs.linuxPackages` is built with `autoModules = true`, which answers "m" to
# every question the kernel's config script asks.  That is the right default
# for a distribution kernel and the wrong one here: it produces 126 MiB of
# modules - 9% of this image - for hardware that consists of a VMBus, one
# synthetic disk controller, one synthetic NIC and a synthetic keyboard.
#
# Stage one, which is what this file is, does not delete anything by hand.  It
# turns `autoModules` off, so unanswered questions fall back to the
# architecture default instead of becoming modules, and then states the things
# this appliance is not allowed to lose.  Stage two removes whole subsystems;
# it is a separate change with its own measurement, because a kernel that
# fails to boot should point at one commit and not two.
#
# Everything below is either "Hyper-V needs it", "the boot path needs it" or
# "the tests need it".  The last category is deliberate: tests/xrdp-session.nix
# and tests/spotibox-basic.nix run under QEMU with virtio and a 9p store, and
# tools/cold-boot.sh attaches the image to an AHCI port.  A kernel that only
# boots on Hyper-V is a kernel nobody can check before shipping, so virtio, 9p
# and AHCI are part of the contract and are named here rather than surviving by
# accident.
lib.mkIf (config.qubix.kernel == "hyperv") {
  # NixOS puts a fixed list of modules into every initrd - SATA and PATA
  # controllers, NVMe, SD card readers, and one entry per USB keyboard vendor
  # that ever needed a quirk.  The list exists for machines nobody has seen
  # yet; this one is known down to the bus.  Worse, it is a hard error rather
  # than a hint: `modprobe` in the modules-shrunk step fails the build outright
  # when a name is missing, so the first thing a trimmed kernel produces is
  # `FATAL: Module hid_corsair not found`.
  #
  # What stays is what the initrd has to find a root filesystem with.  Nearly
  # all of it is built into this kernel rather than modular, which is the point
  # of kernelPreferBuiltin: a built-in driver cannot be missing from an initrd.
  boot.initrd.includeDefaultModules = false;

  boot.kernelPackages = pkgs.linuxPackagesFor (
    pkgs.linuxPackages.kernel.override {
      autoModules = false;
      kernelPreferBuiltin = true;

      # `make config` may answer a question differently from what is asked here
      # when another symbol selects it.  Without this the build stops on the
      # first such case, which turns a 40-minute compile into a guessing game.
      ignoreConfigErrors = true;

      structuredExtraConfig = with lib.kernel; {
        # --- Hyper-V ---------------------------------------------------------
        # The bus, and the four synthetic devices this machine has.  Built in
        # rather than modular: the initrd loads all of them anyway, and a
        # built-in driver is one less thing that can be missing from it.
        HYPERV = yes;
        HYPERV_UTILS = yes;
        HYPERV_BALLOON = yes;
        HYPERV_STORAGE = yes;
        HYPERV_NET = yes;
        HYPERV_KEYBOARD = yes;
        PCI_HYPERV = option yes;
        PCI_HYPERV_INTERFACE = option yes;
        HYPERV_IOMMU = option yes;
        # The console this machine shows in Hyper-V Manager, and the only
        # display it has until xrdp starts its own X server.  It is a DRM
        # driver, not an fbdev one - nixpkgs turns the legacy FB_HYPERV off in
        # favour of it from 5.14 on - which means DRM, its fbdev emulation and
        # the framebuffer console are part of the boot contract, and stage two
        # cannot simply delete the graphics subsystem.  Forced built-in rather
        # than left as nixpkgs' module: there is one display, it is there from
        # power-on, and a built-in driver is one less thing that can fail to
        # load.  DRM_BOCHS is the same display for QEMU, which is what
        # tools/cold-boot.sh screendumps.
        DRM_HYPERV = lib.mkForce yes;
        DRM_BOCHS = option module;

        # --- The boot path ---------------------------------------------------
        # EFI, EFI_STUB, PARTITION_ADVANCED, DRM, the framebuffer console and
        # the VFAT codepages are already pinned by nixpkgs' common-config, so
        # naming them here would either conflict with it or pretend this file
        # is what guarantees them.  tests/kernel-contract.nix checks the
        # finished .config instead, which is the only place the whole contract
        # is actually visible.
        EFI_PARTITION = yes;

        # boot.initrd.systemd puts tpm-crb and tpm-tis in the initrd's module
        # list whether or not the machine has a TPM, and a name that does not
        # resolve is a build failure rather than a warning.  Hyper-V generation
        # 2 VMs can be given a vTPM, so these are cheap and not a lie.
        TCG_TPM = yes;
        TCG_TIS = yes;
        TCG_CRB = yes;
        EFIVAR_FS = option module;
        BLK_DEV_SD = yes;
        BLK_DEV_DM = yes;
        BLK_DEV_LOOP = option module;

        # --- Filesystems the appliance cannot boot without -------------------
        # ext4 is the root, vfat is the ESP, and the last two are not optional
        # since profiles/modes/prod.nix went perlless: system.etc.overlay
        # mounts an erofs metadata image and an overlayfs on top of it, so /etc
        # does not exist without either of them.
        EXT4_FS = yes;
        VFAT_FS = yes;
        FAT_FS = yes;
        OVERLAY_FS = yes;
        EROFS_FS = yes;
        # systemd mounts /sys/fs/fuse/connections on start.
        FUSE_FS = yes;
        AUTOFS_FS = yes;
        TMPFS_XATTR = yes;
        DEVTMPFS_MOUNT = yes;

        # --- The firewall ----------------------------------------------------
        # Turning autoModules off took nftables with it, and
        # tests/kernel-contract.nix is what noticed.  NixOS's firewall is
        # iptables-nft: `nft list ruleset` on a running appliance prints
        # "table ip filter is managed by iptables-nft", so the nft backend and
        # its compatibility layer are what actually carry the rules that make
        # 3389 the only way in.  The reverse-path matches go with them -
        # networking.firewall.checkReversePath is on by default, and a rule
        # that cannot be applied fails the firewall unit rather than being
        # skipped.
        NF_TABLES = yes;
        NFT_COMPAT = yes;
        NETFILTER_XT_MATCH_PKTTYPE = option module;
        IP_NF_MATCH_RPFILTER = option module;
        IP6_NF_MATCH_RPFILTER = option module;

        # --- What the tests run on -------------------------------------------
        # QEMU, in three shapes: the NixOS test driver (virtio disk, virtio
        # console, 9p store), tools/cold-boot.sh (AHCI), and virtiofs, which
        # the test driver uses on newer nixpkgs.
        # nixos/modules/profiles/qemu-guest.nix names all of these, and a name
        # in an initrd module list that does not resolve is a build failure,
        # not a warning.  Built in rather than modular for the same reason the
        # Hyper-V drivers are: it is one less thing that can be missing.
        VIRTIO = yes;
        VIRTIO_PCI = yes;
        VIRTIO_MMIO = yes;
        VIRTIO_BLK = yes;
        # SCSI_VIRTIO, not VIRTIO_SCSI.  The wrong name is not an error:
        # ignoreConfigErrors swallows it and the option quietly does nothing,
        # which is what tests/kernel-contract.nix exists to notice.
        SCSI_VIRTIO = yes;
        VIRTIO_NET = yes;
        VIRTIO_CONSOLE = yes;
        VIRTIO_BALLOON = yes;
        HW_RANDOM_VIRTIO = yes;
        DRM_VIRTIO_GPU = yes;
        NET_9P = yes;
        NET_9P_VIRTIO = yes;
        "9P_FS" = yes;
        VIRTIO_FS = option yes;
        ATA = yes;
        ATA_PIIX = option yes;
        SATA_AHCI = yes;
      };
    }
  );
}
