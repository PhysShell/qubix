{ config, lib, pkgs, modulesPath, ... }:

# Qubix's version of the upstream Hyper-V image.
#
# nixos/modules/virtualisation/hyperv-image.nix calls make-disk-image.nix
# without passing `copyChannel`, and that argument defaults to true.  The image
# therefore gets a full nixpkgs source tree copied into its store and
# registered as the root user's `nixos` channel — hundreds of megabytes of
# Nix expressions, shipped inside an appliance whose only job is to play music
# and which is thrown away and rebuilt on every recreate.
#
# There is no NixOS option for this: copyChannel is a function argument, so the
# only way to change it is to call make-disk-image ourselves and override the
# derivation the format builds.  Everything except `copyChannel` below is a
# copy of upstream's call and has to stay in sync with it; the option it feeds
# is documented in nixos/lib/make-disk-image.nix.
#
# Debug images keep the channel: `nixos-rebuild switch` inside the guest is a
# real debugging workflow, and debug images are allowed to be fat.

let
  mkHypervImage = copyChannel: import "${modulesPath}/../lib/make-disk-image.nix" {
    name = config.hyperv.vmDerivationName;
    baseName = config.image.baseName;
    postVM = ''
      ${pkgs.vmTools.qemu}/bin/qemu-img convert -f raw -o subformat=dynamic -O vhdx $diskImage $out/${config.image.fileName}
      rm $diskImage
    '';
    format = "raw";
    inherit (config.virtualisation) diskSize;
    partitionTableType = "efi";
    inherit copyChannel config lib pkgs;
  };
in
{
  # system.build.image follows hypervImage upstream, so overriding this one
  # attribute is enough for both `nixos-generators` and `nix build .#*-vhdx`.
  system.build.hypervImage =
    lib.mkForce (mkHypervImage (config.qubix.mode != "prod"));
}
