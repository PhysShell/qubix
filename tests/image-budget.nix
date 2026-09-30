# Image-level size budget, written by `tools/telemetry.sh --record`
# and enforced by `tools/telemetry.sh` in the release job.
#
# tests/closure-budget.nix gates the closure, which every pull request
# can afford to measure.  This gates what only a finished image knows:
# what the VHDX costs the host - its apparent size, since qubixctl
# writes it out in full - and what the release asset costs to download.
# vhdxBuilderAllocatedBytes is the builder's sparse view of the same
# file, not a host cost.  Re-record deliberately, and say why in the
# commit that follows.  --record measures only from a commit, in a fresh
# store with every build sandboxed: the numbers belong to the commit,
# not to the machine that took them.
{
  spotibox = {
    # What the numbers below were measured against.
    nixosVersion = "hyperv-25.11.20260501.26ef669";
    rev = "345c420de288eccbdf85d2614ad0e029bc28437f";

    closureBytes = { measured = 1187190640; max = 1246550172; };
    closurePaths = { measured = 572; max = 600; };
    kernelBytes = { measured = 24995768; max = 26245556; };
    modulesBytes = { measured = 1791416; max = 1880986; };
    initrdBytes = { measured = 23092240; max = 24246852; };
    vhdxApparentBytes = { measured = 1686110208; max = 1770415718; };
    vhdxBuilderAllocatedBytes = { measured = 1374699520; max = 1443434496; };
    releaseBytes = { measured = 505700521; max = 530985547; };
    homeReleaseBytes = { measured = 420606; max = 441636; };
  };
}
