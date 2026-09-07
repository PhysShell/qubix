{ config, ... }:

{
  # UIDs are pinned because /home is a persistent disk that outlives the
  # system image.  NixOS would otherwise allocate UIDs in alphabetical order
  # at activation time, and adding a user later could silently shift them —
  # leaving the persistent home directories owned by the wrong account.

  # Main interactive user for local/Hyper-V console work.
  #
  # This is a disposable lab image. Replace the plaintext initialPassword with
  # initialHashedPassword before using Qubix for anything less throwaway.
  users.users.user = {
    isNormalUser = true;
    uid = 1000;
    initialPassword = config.qubix.labPassword;
    extraGroups = [ "wheel" "audio" ];
  };

  # Dedicated RDP user.
  #
  # Hyper-V enhanced sessions and xrdp sessions can fight over DISPLAY, DBus and
  # PulseAudio state when the same account is used in both places. Keeping mstsc
  # on a separate Unix user gives it a separate user bus and PulseAudio world.
  users.users.rdp = {
    isNormalUser = true;
    uid = 1001;
    initialPassword = config.qubix.labPassword;
    extraGroups = [ "wheel" "audio" ];
  };
}
