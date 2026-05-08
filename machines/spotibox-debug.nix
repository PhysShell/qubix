{ lib, ... }:

{
  imports = [
    ./spotibox.nix
  ];

  networking.hostName = lib.mkForce "spotibox-debug";
  qubix.mode = lib.mkForce "debug";
}
