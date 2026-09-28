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
    rev = "7cf3e813d742e41a284560b83dcc7858ceba7d8d";

    closureBytes = { measured = 1222866800; max = 1284010140; };
    closurePaths = { measured = 579; max = 607; };
    kernelBytes = { measured = 24995768; max = 26245556; };
    modulesBytes = { measured = 1791416; max = 1880986; };
    initrdBytes = { measured = 23092240; max = 24246852; };
    vhdxApparentBytes = { measured = 1719664640; max = 1805647872; };
    vhdxBuilderAllocatedBytes = { measured = 1410596864; max = 1481126707; };
    releaseBytes = { measured = 520302296; max = 546317410; };
    homeReleaseBytes = { measured = 420843; max = 441885; };
  };
}
