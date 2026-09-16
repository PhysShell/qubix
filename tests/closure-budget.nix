# Closure budget for the production Spotibox appliance, in bytes.
#
# Written by `tools/closure.sh baseline`, enforced by `tools/closure.sh check`
# in CI.  The point is not the absolute number - it is that half a desktop
# environment cannot reappear in the image through an innocent-looking
# `environment.systemPackages` line without somebody re-recording it here.
#
# Re-record after any intentional growth, and after a nixpkgs bump.
{
  spotibox = {
    # `nix path-info -S` of
    # nixosConfigurations.spotibox.config.system.build.toplevel.
    measuredBytes = 1229320752;

    # CI fails above this: the measurement plus 2% of headroom.
    maxBytes = 1253907167;

    # What the numbers above were measured against.
    nixosVersion = "25.11.20260501.26ef669";
  };
}
