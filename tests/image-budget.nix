# Image-level size budget, written by `tools/telemetry.sh --record`
# and enforced by `tools/telemetry.sh` in the release job.
#
# tests/closure-budget.nix gates the closure, which every pull request
# can afford to measure.  This gates what only a finished image knows:
# what the VHDX costs the host - its apparent size, since qubixctl
# writes it out in full - and what the release asset costs to download.
# vhdxBuilderAllocatedBytes is the builder's sparse view of the same
# file, not a host cost.  Re-record deliberately, from a commit, and say
# why in the commit that follows.
{
  spotibox = {
    # What the numbers below were measured against.
    nixosVersion = "hyperv-25.11.20260501.26ef669";
    rev = "a814ea70ca3087ad12a21fb42ffbcf723ffc36c3";

    closureBytes = { measured = 1222807776; max = 1283948164; };
    closurePaths = { measured = 579; max = 607; };
    kernelBytes = { measured = 24995768; max = 26245556; };
    modulesBytes = { measured = 1791736; max = 1881322; };
    initrdBytes = { measured = 23096904; max = 24251749; };
    vhdxApparentBytes = { measured = 1736441856; max = 1823263948; };
    vhdxBuilderAllocatedBytes = { measured = 1410531328; max = 1481057894; };
    releaseBytes = { measured = 520362719; max = 546380854; };
    homeReleaseBytes = { measured = 420861; max = 441904; };
  };
}
