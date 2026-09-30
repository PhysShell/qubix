# Closure budget for the production Spotibox appliance, in bytes.
#
# Written by `tools/closure.sh baseline`, enforced by `tools/closure.sh check`
# in CI.  The point is not the absolute number - it is that half a desktop
# environment cannot reappear in the image through an innocent-looking
# `environment.systemPackages` line without somebody re-recording it here.
#
# Re-record after any intentional growth, and after a nixpkgs bump.  The
# baseline measures in a fresh store with every build sandboxed, and only from
# a commit, so the number here is the one CI gets.
{
  spotibox = {
    # `nix path-info -S` of
    # nixosConfigurations.spotibox.config.system.build.toplevel.
    measuredBytes = 1187190640;

    # CI fails above this: the measurement plus 2% of headroom.
    maxBytes = 1210934452;

    # What the numbers above were measured against.
    nixosVersion = "25.11.20260501.26ef669";
    rev = "345c420de288eccbdf85d2614ad0e029bc28437f";
  };
}
