{ config, ... }:

{
  # Main interactive user for local/Hyper-V console work.
  #
  # This is a disposable lab image. Replace the plaintext initialPassword with
  # initialHashedPassword before using Qubix for anything less throwaway.
  users.users.user = {
    isNormalUser = true;
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
    initialPassword = config.qubix.labPassword;
    extraGroups = [ "wheel" "audio" ];
  };
}
