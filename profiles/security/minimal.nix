{ lib, ... }:

{
  networking.firewall.enable = lib.mkDefault true;

  # Avahi makes the Default Switch workflow more tolerable by allowing
  # "spotibox.local" even when Hyper-V DHCP changes the numeric address.
  services.avahi = {
    enable = lib.mkDefault true;
    nssmdns4 = lib.mkDefault true;
    openFirewall = lib.mkDefault true;
  };

  services.openssh.enable = lib.mkDefault false;
  security.sudo.wheelNeedsPassword = lib.mkDefault true;
  boot.tmp.cleanOnBoot = lib.mkDefault true;

  # TODO: Add Spotify network lockdown.
  # Candidate: nftables outbound policy for the normal user, or proxy/DNS
  # allowlisting. A pure IP allowlist is brittle because Spotify uses dynamic
  # CDN and login infrastructure.
}
