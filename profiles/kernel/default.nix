{ config, lib, pkgs, ... }:

lib.mkIf (config.qubix.kernel == "default") {
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages;
}
