#!/usr/bin/env bash
# Image-level size telemetry, recorded per release.
#
#   tools/telemetry.sh            measure, compare against the recorded budget
#   tools/telemetry.sh --record   measure and write tests/image-budget.nix
#   tools/telemetry.sh --json     just the JSON, for a release asset
#
# tools/closure.sh gates `system.build.toplevel`, which is cheap enough to run
# on every pull request.  This gates the things only a finished image can tell
# you - what the VHDX occupies on a Windows host, what the release asset costs
# to download, how much of either is kernel - and so it runs where the image
# is already being built: the release job.
#
# The point is not any single number.  It is that six months from now an
# innocent-looking package cannot quietly put half a desktop environment back
# without somebody re-recording it here and explaining why in the diff.
set -euo pipefail
cd "$(dirname "$0")/.."

budget_file=tests/image-budget.nix
mode=check
case "${1:-}" in
  --record) mode=record ;;
  --json)   mode=json ;;
  "")       ;;
  *) echo "usage: $0 [--record|--json]" >&2; exit 2 ;;
esac

# Headroom recorded on top of a fresh measurement, in percent.  Larger than
# the closure gate's 2%: gzip output moves with the compressor's mood and a
# dynamic VHDX allocates in extents, so image numbers are noisier than a
# closure size, which is a sum of exact NAR sizes.
headroom_percent=5

say() { [ "$mode" = json ] || echo "$@" >&2; }

say "building toplevel, image and release bundle..."
toplevel=$(nix build --no-link --print-out-paths .#spotibox-toplevel)
image=$(nix build --no-link --print-out-paths .#spotibox-vhdx)
release=$(nix build --no-link --print-out-paths .#spotibox-release)

vhdx=$(find -L "$image" -name '*.vhdx' -print -quit)
test -n "$vhdx" || { echo "no .vhdx in $image" >&2; exit 1; }

# Own NAR size of the closure paths whose *name* matches, with the number of
# paths that may match stated up front.
#
# Two lessons are baked in here.  The name and not the path, because
# `-linux-6.12.85$` also matches `...-initrd-linux-6.12.85`, which is how the
# first version of this counted the initrd twice and reported a 46 MiB kernel.
# And an exact count, because after that there is no reason left to trust
# store naming on its own: a classifier that silently matches nothing reports
# zero bytes and looks like an improvement, and one that silently matches an
# extra path looks like a regression.  Either way the number is wrong and
# nobody finds out.  If nixpkgs changes the shape of these paths, this stops
# the release and prints what it found.
nar_of() {
  local pat="$1" want="$2" found
  found=$(nix path-info -rs "$toplevel" |
    awk -v pat="$pat" '
      { name = substr($1, length("/nix/store/") + 34) }
      name ~ pat { print $1 "\t" $2 }')

  local n
  n=$(printf '%s' "$found" | grep -c . || true)
  if [ "$n" != "$want" ]; then
    {
      echo "telemetry.sh: /$pat/ matched $n closure paths, expected $want."
      echo "The store layout changed, or the pattern is wrong.  Matched:"
      printf '%s\n' "$found" | sed 's|^|  |'
    } >&2
    exit 1
  fi
  printf '%s' "$found" | awk -F'\t' '{ sum += $2 } END { print sum + 0 }'
}

version=$(nix eval --raw .#nixosConfigurations.spotibox.config.system.nixos.label)
# The commit this was measured on.  Marked dirty when the tree was, because
# a budget recorded from uncommitted work names its parent commit and would
# otherwise claim a provenance it does not have.
rev=$(git rev-parse HEAD 2>/dev/null || echo unknown)
git diff --quiet HEAD 2>/dev/null || rev="$rev-dirty"

closure_bytes=$(nix path-info -S "$toplevel" | awk '{ print $2 }')
closure_paths=$(nix path-info -r "$toplevel" | wc -l)
# The counts are part of the contract.  Three trees of kernel modules ship,
# and the count is here so that nobody has to remember why:
#
#   linux-<v>-modules         the kernel's own tree, and nearly all the bytes
#   linux-<v>-modules         352 bytes of symlink farm, which is what
#                             aggregateModules builds to merge in
#                             boot.extraModulePackages - of which this image
#                             has none
#   linux-<v>-modules-shrunk  the subset make-initrd copies into the initrd
#
# An earlier version of this line had no `$` and counted the first two; the
# one before that had no count at all and quietly folded in the initrd.  Both
# looked like a size change rather than a measurement bug, which is the whole
# argument for stating how many paths a classifier is allowed to match.
kernel_bytes=$(nar_of '^linux-[0-9][^-]*$' 1)
modules_bytes=$(nar_of '^linux-[0-9][^-]*-modules' 3)
initrd_bytes=$(nar_of '^initrd-linux-' 1)
vhdx_apparent=$(stat -L -c %s "$vhdx")
vhdx_allocated=$(( $(stat -L -c %b "$vhdx") * $(stat -L -c %B "$vhdx") ))
release_bytes=$(stat -L -c %s "$release/spotibox.vhdx.gz")
home_release_bytes=$(stat -L -c %s "$release/spotibox-home.vhdx.gz")

metrics=(closure_bytes closure_paths kernel_bytes modules_bytes initrd_bytes
         vhdx_apparent vhdx_allocated release_bytes home_release_bytes)

# Nix attribute names, so the budget file reads like the rest of tests/.
attr_of() {
  case "$1" in
    closure_bytes)      echo closureBytes ;;
    closure_paths)      echo closurePaths ;;
    kernel_bytes)       echo kernelBytes ;;
    modules_bytes)      echo modulesBytes ;;
    initrd_bytes)       echo initrdBytes ;;
    vhdx_apparent)      echo vhdxApparentBytes ;;
    vhdx_allocated)     echo vhdxAllocatedBytes ;;
    release_bytes)      echo releaseBytes ;;
    home_release_bytes) echo homeReleaseBytes ;;
  esac
}

if [ "$mode" = json ]; then
  printf '{\n'
  printf '  "nixosVersion": "%s",\n  "rev": "%s",\n' "$version" "$rev"
  for m in "${metrics[@]}"; do
    printf '  "%s": %s' "$(attr_of "$m")" "${!m}"
    [ "$m" = "${metrics[-1]}" ] && printf '\n' || printf ',\n'
  done
  printf '}\n'
  exit 0
fi

human() {
  case "$1" in
    closure_paths) echo "${2} paths" ;;
    *) numfmt --to=iec-i --format='%.1f' --suffix=B "$2" ;;
  esac
}

if [ "$mode" = record ]; then
  {
    echo "# Image-level size budget, written by \`tools/telemetry.sh --record\`"
    echo "# and enforced by \`tools/telemetry.sh\` in the release job."
    echo "#"
    echo "# tests/closure-budget.nix gates the closure, which every pull request"
    echo "# can afford to measure.  This gates what only a finished image knows:"
    echo "# what the VHDX occupies on the host and what the release asset costs"
    echo "# to download.  Re-record deliberately, and say why in the commit."
    echo "{"
    echo "  spotibox = {"
    echo "    # What the numbers below were measured against."
    echo "    nixosVersion = \"$version\";"
    echo "    rev = \"$rev\";"
    echo
    for m in "${metrics[@]}"; do
      max=$(( ${!m} + ${!m} * headroom_percent / 100 ))
      printf '    %s = { measured = %s; max = %s; };\n' \
        "$(attr_of "$m")" "${!m}" "$max"
    done
    echo "  };"
    echo "}"
  } > "$budget_file"
  say "recorded $budget_file"
fi

if [ ! -f "$budget_file" ]; then
  echo "no $budget_file yet - run '$0 --record'" >&2
  exit 1
fi

fail=0
printf '%-20s %14s %14s %10s %14s\n' metric measured recorded delta budget
for m in "${metrics[@]}"; do
  attr=$(attr_of "$m")
  old=$(nix eval --raw --impure --expr \
    "toString (import ./$budget_file).spotibox.$attr.measured")
  max=$(nix eval --raw --impure --expr \
    "toString (import ./$budget_file).spotibox.$attr.max")
  now=${!m}
  delta=$(( now - old ))
  sign=$([ "$delta" -ge 0 ] && echo + || echo -)
  over=""
  if [ "$now" -gt "$max" ]; then over="  OVER"; fail=1; fi
  printf '%-20s %14s %14s %9s%s %14s%s\n' \
    "$attr" "$(human "$m" "$now")" "$(human "$m" "$old")" \
    "$sign" "$(human "$m" "${delta#-}")" "$(human "$m" "$max")" "$over"
done

if [ "$fail" != 0 ]; then
  echo >&2
  echo "::error::the image grew past tests/image-budget.nix" >&2
  echo "Re-record with 'tools/telemetry.sh --record' only when the growth is" >&2
  echo "something you meant, and say what it bought in the commit message." >&2
  exit 1
fi
echo "ok: every metric inside its budget"
