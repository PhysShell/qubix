{ pkgs, lib, seed }:

# Evaluation-only pin for the home seed's filesystem identity.
#
# mkHomeSeed in flake.nix derives the seed's ext4 UUID - and the directory hash
# seed, which is the same value - from the machine's name and the disk's label,
# so two builds of one commit write the same filesystem byte for byte;
# tools/repro-census.sh is what checks that.  This pins the value itself.  A
# change to how it is derived changes every seed image from then on, and ought
# to say so in a diff rather than slip in with a refactor.  /home is mounted by
# label, so nothing running cares which UUID it is - only that it is this one.

let
  uuid = seed.fsUuid;
  pinned = "7ceca65b-84ae-8be4-8f2d-7c2425ba302c";
  version8 = "[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
in
assert lib.assertMsg (builtins.match version8 uuid != null)
  "home seed UUID ${uuid} is not an RFC 9562 version 8 UUID";
assert lib.assertMsg (uuid == pinned)
  "home seed UUID is ${uuid}, pinned ${pinned}: every seed image changes with it, so update the pin on purpose";
pkgs.runCommand "spotibox-home-seed-identity" { } ''
  echo ${uuid} > $out
''
