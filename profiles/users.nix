{ config, lib, ... }:

let
  debug = config.qubix.mode == "debug";
in
{
  # UIDs are pinned because /home is a persistent disk that outlives the
  # system image.  NixOS would otherwise allocate UIDs in alphabetical order
  # at activation time, and adding a user later could silently shift them —
  # leaving the persistent home directories owned by the wrong account.
  #
  # Pinning is also what makes the account list below safe to change: `rdp`
  # keeps uid 1001 whether or not `user` exists, so a production image and a
  # debug image built from the same home disk agree about who owns what.

  users.users = {
    # The only account on a production appliance.  Hyper-V enhanced sessions
    # and xrdp sessions fight over DISPLAY, DBus and PulseAudio state when the
    # same account is used in both places, which is why mstsc gets a Unix user
    # of its own — and, now, why that user is the whole list.
    #
    # Not in `wheel`.  This is the account a remote client logs into with a
    # password that is published in this repository; giving it sudo would make
    # the separation above decorative.  Nothing in the kiosk session asks for
    # root: it starts Openbox and Spotify and exits when Spotify does.
    #
    # Not in `audio` either, on production images.  That group exists to grant
    # access to /dev/snd, and there is no /dev/snd: audio leaves this machine
    # over the RDP channel, through a PulseAudio sink that opens no device,
    # and profiles/kernel/hyperv.nix builds a kernel with no sound support at
    # all.  Debug images keep it, because they keep a kernel that has ALSA.
    rdp = {
      isNormalUser = true;
      uid = 1001;
      initialPassword = config.qubix.labPassword;
      extraGroups = lib.optionals debug [ "audio" ];
    };
  }
  # The interactive account for local and Hyper-V console work.  It exists to
  # be logged into and to run commands as root, which is a description of a
  # debugging tool rather than of an appliance: production has no console
  # anybody is expected to use, no sshd to reach one with, and nothing for a
  # second account to do that the kiosk session does not already do.
  #
  # This is a disposable lab image.  Replace the plaintext initialPassword
  # with initialHashedPassword before using Qubix for anything less throwaway.
  // lib.optionalAttrs debug {
    user = {
      isNormalUser = true;
      uid = 1000;
      initialPassword = config.qubix.labPassword;
      extraGroups = [ "wheel" "audio" ];
    };
  };
}
