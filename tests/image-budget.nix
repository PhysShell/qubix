# Image-level size budget, written by `tools/telemetry.sh --record`
# and enforced by `tools/telemetry.sh` in the release job.
#
# tests/closure-budget.nix gates the closure, which every pull request
# can afford to measure.  This gates what only a finished image knows:
# what the VHDX occupies on the host and what the release asset costs
# to download.  Re-record deliberately, and say why in the commit.
{
  spotibox = {
    # What the numbers below were measured against.
    nixosVersion = "hyperv-25.11.20260501.26ef669";
    rev = "36a369e42eb67a2465374ff6b00b9b437522f321-dirty";

    closureBytes = { measured = 1222807776; max = 1283948164; };
    closurePaths = { measured = 579; max = 607; };
    kernelBytes = { measured = 24995768; max = 26245556; };
    modulesBytes = { measured = 1791736; max = 1881322; };
    initrdBytes = { measured = 23096904; max = 24251749; };
    vhdxApparentBytes = { measured = 1736441856; max = 1823263948; };
    vhdxAllocatedBytes = { measured = 1410531328; max = 1481057894; };
    releaseBytes = { measured = 520362719; max = 546380854; };
    homeReleaseBytes = { measured = 420861; max = 441904; };
  };
}
