#!/usr/bin/env bash
# Reproducibility census of the images: builds each one twice, from the same
# inputs, and says where the two builds differ.
#
#   tools/repro-census.sh
#
# The closure the images are made of is reproducible - two sandboxed builds,
# one of them CI's, agree on it to the byte - and the images are not.  Each
# image passes through layers, and a difference belongs to one of them:
#
#   home seed      ext4 filesystem, bare       -> VHDX -> .gz in the release
#   system image   GPT: ESP (FAT) + ext4 root  -> VHDX -> .gz in the release
#
# So every image derivation is built in a fresh, sandboxed store (see
# tools/lib/measure.sh) and then rebuilt with --rebuild: same inputs, a second
# run.  Where the two outputs differ, both VHDX files are read back to raw
# with qemu-img, which puts each difference in its layer - the filesystem
# inside, or the container around it - and tools/lib/image-diff.py names the
# structure it sits in.  The release bundle is rebuilt from one and the same
# pair of images, so any difference there is gzip's own.
#
# Needs KVM for the system image, like any build of it, and several GiB of
# $TMPDIR for the store and the raw read-backs, which are sparse.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/lib/measure.sh
. tools/lib/measure.sh

measure_in_fresh_store
require_sandbox

tools=$(nix build --no-link --print-out-paths \
  .#nixosConfigurations.spotibox.pkgs.qemu-utils \
  .#nixosConfigurations.spotibox.pkgs.python3)
qemu_img=$(printf '%s\n' "$tools" | grep qemu-utils)/bin/qemu-img
python=$(printf '%s\n' "$tools" | grep python3)/bin/python3
diff_tool="$(pwd)/tools/lib/image-diff.py"
scratch=$(mktemp -d -t qubix-census.XXXXXX)
trap 'rm -rf -- "${scratch:?}"; measure_cleanup' EXIT

echo "census of $(measure_rev), $(date -u +%Y-%m-%d)"
echo "building the images once..." >&2
for attr in spotibox-home-vhdx spotibox-vhdx spotibox-release; do
  nix_build --no-link ".#$attr"
done

sha() { sha256sum "$1" | cut -d' ' -f1; }

# The file an image output holds: the home seed is the output itself, the
# system image a directory with one .vhdx in it.
vhdx_in() {
  if [ -d "$1" ]; then find "$1" -name '*.vhdx' -print -quit; else echo "$1"; fi
}

verdict=0
for attr in spotibox-home-vhdx spotibox-vhdx spotibox-release; do
  echo >&2
  echo "rebuilding $attr from the same inputs..." >&2
  out=$(nix_build --no-link --print-out-paths ".#$attr")
  # --rebuild fails exactly when the second build differs; --keep-failed
  # keeps that build next to the first, as <out>.check.
  nix_build --no-link --rebuild --keep-failed ".#$attr" 2>"$scratch/rebuild.log" || true
  first=$(host_path "$out")
  second="$first.check"

  echo "== $attr"
  if [ ! -e "$second" ]; then
    if grep -q 'error:' "$scratch/rebuild.log"; then
      sed 's/^/  /' "$scratch/rebuild.log"
      echo "  the rebuild failed; no verdict"
      verdict=1
      continue
    fi
    if [ "$attr" = spotibox-release ]; then
      echo "  gzip is reproducible: rebuilt from the same two images, identical"
    else
      echo "  reproducible: a second build from the same inputs is identical"
    fi
    continue
  fi
  verdict=1

  if [ "$attr" = spotibox-release ]; then
    echo "  rebuilt from the same two images, and still:"
    for f in "$first"/*; do
      name=$(basename "$f")
      if [ "$(sha "$f")" = "$(sha "$second/$name")" ]; then
        echo "  $name: identical"
      else
        echo "  $name: differs"
      fi
    done
    continue
  fi

  a=$(vhdx_in "$first")
  b=$(vhdx_in "$second")
  echo "  sha256 $(sha "$a")"
  echo "  sha256 $(sha "$b")"
  "$python" "$diff_tool" vhdx "$a" "$b" | sed 's/^/  /'
  "$qemu_img" convert -f vhdx -O raw -S 4k "$a" "$scratch/a.raw"
  "$qemu_img" convert -f vhdx -O raw -S 4k "$b" "$scratch/b.raw"
  "$python" "$diff_tool" raw "$scratch/a.raw" "$scratch/b.raw" | sed 's/^/  /'
  rm -f "$scratch/a.raw" "$scratch/b.raw"
done

exit "$verdict"
