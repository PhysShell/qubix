#!/usr/bin/env bash
# Closure census and budget for the appliance images.
#
#   tools/closure.sh report [ATTR]   size of one system plus its heaviest paths
#   tools/closure.sh diff            what the debug image carries and prod does not
#   tools/closure.sh why NEEDLE      why the production image still contains NEEDLE
#   tools/closure.sh roots [N]       system packages ranked by what they alone cost
#   tools/closure.sh check           CI gate: budget, and no nixpkgs channel in the image
#   tools/closure.sh baseline        record today's production size as the budget
#
# Everything measures `system.build.toplevel`, not the VHDX.  An image is that
# closure plus a filesystem around it, toplevel builds without KVM, and the
# numbers are stable enough to compare across machines.
#
# Nothing here deletes anything.  A store path ships because something in the
# system still refers to it, so the only way to make an image smaller is to
# remove the reference and let Nix stop copying the path - `nix-store --gc`
# inside the guest would be shouting at the wrong end of the pipeline.
set -euo pipefail
cd "$(dirname "$0")/.."

# Matches the single `system` in flake.nix.
system=x86_64-linux
prod_attr=spotibox-toplevel
debug_attr=spotibox-debug-toplevel
image_drv_attr=".#nixosConfigurations.spotibox.config.system.build.hypervImage"
budget_file=tests/closure-budget.nix

# Headroom recorded on top of a fresh measurement, in percent.  Big enough that
# a nixpkgs bump does not fail an unrelated pull request, small enough that a
# forgotten `environment.systemPackages = [ gimp ]` does.
headroom_percent=2

die() { echo "closure.sh: $*" >&2; exit 1; }

build() {
  nix build --no-link --print-out-paths ".#$1"
}

# Total size of a store path's closure, in bytes.
closure_bytes() {
  nix path-info -S "$1" | awk '{ print $2 }'
}

# Binary units, spelled out: `nix path-info -h` rounds harder than is useful
# when the whole point is comparing two numbers that are close together.
human() {
  numfmt --to=iec-i --format='%.1f' --suffix=B "$1"
}

# Store paths of one closure, largest own (NAR) size first: "bytes<TAB>path".
by_size() {
  nix path-info -rs "$1" | awk '{ print $2 "\t" $1 }' | sort -nr
}

cmd_report() {
  local attr="${1:-$prod_attr}" top="${2:-25}" out total
  out=$(build "$attr")
  total=$(closure_bytes "$out")

  echo "$attr"
  echo "  $out"
  echo "  closure: $(human "$total") ($total bytes)"
  echo
  echo "  heaviest $top paths (own size, not closure size):"
  by_size "$out" | head -"$top" | while IFS=$'\t' read -r size path; do
    printf '    %10s  %s\n' "$(human "$size")" "${path#/nix/store/}"
  done
  echo
  echo "  ask why any of them is still there with: tools/closure.sh why NAME"
}

cmd_diff() {
  local prod debug
  prod=$(build "$prod_attr")
  debug=$(build "$debug_attr")

  echo "prod:  $(human "$(closure_bytes "$prod")")  $prod"
  echo "debug: $(human "$(closure_bytes "$debug")")  $debug"
  echo
  echo "only in the debug image:"
  comm -13 \
    <(nix path-info -r "$prod" | sort) \
    <(nix path-info -r "$debug" | sort) |
    while read -r path; do
      printf '  +%10s  %s\n' "$(human "$(nix path-info -s "$path" | awk '{ print $2 }')")" "${path#/nix/store/}"
    done

  echo
  echo "only in the production image:"
  comm -23 \
    <(nix path-info -r "$prod" | sort) \
    <(nix path-info -r "$debug" | sort) |
    while read -r path; do
      printf '  -%10s  %s\n' "$(human "$(nix path-info -s "$path" | awk '{ print $2 }')")" "${path#/nix/store/}"
    done
}

cmd_why() {
  local needle="${1:-}" prod matches
  [ -n "$needle" ] || die "usage: tools/closure.sh why NEEDLE"
  prod=$(build "$prod_attr")

  matches=$(nix path-info -r "$prod" | grep -- "$needle" || true)
  [ -n "$matches" ] || { echo "no path matching '$needle' in the production closure"; return 0; }

  echo "$matches" | head -5 | while read -r path; do
    echo "=== $path"
    nix why-depends "$prod" "$path"
    echo
  done
}

# `why` answers "who is holding this", which is the wrong question when you are
# choosing what to remove next: a 300 MiB package can be free if everything it
# needs is already in the closure for other reasons.  This answers the right
# one - how much of the closure disappears if this root, and nothing else, goes
# away.  That is `nix-tree`'s "added size", computed over the reference graph
# instead of guessed from closure sizes.
#
# Needs python3 on PATH for the graph walk; the rest of this script is bash.
cmd_roots() {
  local top="${1:-20}" out tmp
  out=$(build "$prod_attr")
  command -v python3 >/dev/null || die "roots needs python3 on PATH"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN

  nix eval --json \
    ".#nixosConfigurations.spotibox.config.environment.systemPackages" \
    --apply 'ps: map (p: p.outPath) ps' > "$tmp/roots.json"
  nix path-info -r "$out" > "$tmp/paths.txt"
  nix path-info -rs "$out" > "$tmp/sizes.txt"

  TOP="$out" N="$top" python3 - "$tmp" <<'PYROOTS'
import json, os, subprocess, sys
tmp = sys.argv[1]
top = os.environ["TOP"]
n = int(os.environ["N"])

paths = [l.strip() for l in open(f"{tmp}/paths.txt") if l.strip()]
sizes = {}
for line in open(f"{tmp}/sizes.txt"):
    a = line.split()
    if len(a) >= 2:
        sizes[a[0]] = int(a[1])
refs = {
    p: subprocess.run(["nix-store", "-q", "--references", p],
                      capture_output=True, text=True).stdout.split()
    for p in paths
}

def reach(blocked):
    seen, stack = set(), [top]
    while stack:
        x = stack.pop()
        if x in seen or x in blocked:
            continue
        seen.add(x)
        stack.extend(refs.get(x, []))
    return seen

full = reach(set())
total = sum(sizes.get(p, 0) for p in full)
# systemPackages lists some packages more than once (every user's shell, for
# one), and the same path twice is the same removal.
roots = list(dict.fromkeys(r for r in json.load(open(f"{tmp}/roots.json")) if r in refs))

rows = []
for r in roots:
    gone = full - reach({r})
    rows.append((sum(sizes.get(p, 0) for p in gone), len(gone), r))
rows.sort(reverse=True)

def mib(b):
    return f"{b / 2**20:8.1f} MiB"

print(f"closure: {mib(total)} over {len(full)} paths, {len(roots)} system packages")
print(f"\n{'added size':>12} {'paths':>6}  package")
for size, count, r in rows[:n]:
    print(f"{mib(size)} {count:>6}  {r.split('/')[-1][33:]}")
print("\nadded size = what leaves the closure if this package alone is dropped.")
PYROOTS
}

# The other half of the budget: upstream's Hyper-V image copies a full nixpkgs
# source tree into the VHDX as the root user's channel, because
# make-disk-image's copyChannel argument defaults to true and
# nixos/modules/virtualisation/hyperv-image.nix never overrides it.
# profiles/image/hyperv.nix does.  This checks the image derivation itself, so
# it keeps working if a nixpkgs bump reshuffles the module - eval only, no
# build, no KVM.
cmd_image_channel() {
  local version needle drv
  version=$(nix eval --raw ".#nixosConfigurations.spotibox.config.system.nixos.version")
  needle="-nixos-${version}.drv"

  # The channel is copied by the image derivation itself, so the inputs of that
  # one derivation are enough - and instantiating it needs neither KVM nor the
  # nixos-generators input.  `nix derivation show` writing nothing at all would
  # otherwise read as a pass, so capture it first and let set -e see the exit
  # status.
  drv=$(nix derivation show "$image_drv_attr")

  if printf '%s' "$drv" | grep -qF -- "$needle"; then
    echo "FAIL: the production image still copies a nixpkgs channel into the VHDX"
    echo "      (found $needle among the image derivation's inputs)"
    echo "      profiles/image/hyperv.nix is supposed to pass copyChannel = false."
    return 1
  fi

  echo "ok: no nixpkgs channel in the production image ($needle absent)"
}

cmd_check() {
  local out total max rc=0
  out=$(build "$prod_attr")
  total=$(closure_bytes "$out")

  cmd_image_channel || rc=1

  max=$(nix eval --file "$budget_file" spotibox.maxBytes)
  if [ "$max" = "null" ]; then
    echo "note: no closure budget recorded yet."
    echo "      production closure is $(human "$total") ($total bytes)."
    echo "      run tools/closure.sh baseline and commit $budget_file to arm the gate."
    return "$rc"
  fi

  echo "production closure: $(human "$total") ($total bytes)"
  echo "budget:             $(human "$max") ($max bytes)"

  if [ "$total" -gt "$max" ]; then
    echo
    echo "FAIL: the production appliance grew past its budget by $(human "$((total - max))")."
    echo "      tools/closure.sh diff and tools/closure.sh why NAME say what moved."
    echo "      If the growth is intended, run tools/closure.sh baseline and commit."
    echo
    cmd_report "$prod_attr" 15
    return 1
  fi

  echo "ok: $(human "$((max - total))") of headroom left"
  return "$rc"
}

cmd_baseline() {
  local out total max version
  out=$(build "$prod_attr")
  total=$(closure_bytes "$out")
  max=$(( total + total * headroom_percent / 100 ))
  version=$(nix eval --raw ".#nixosConfigurations.spotibox.config.system.nixos.version")

  cat > "$budget_file" <<EOF
# Closure budget for the production Spotibox appliance, in bytes.
#
# Written by \`tools/closure.sh baseline\`, enforced by \`tools/closure.sh check\`
# in CI.  The point is not the absolute number - it is that half a desktop
# environment cannot reappear in the image through an innocent-looking
# \`environment.systemPackages\` line without somebody re-recording it here.
#
# Re-record after any intentional growth, and after a nixpkgs bump.
{
  spotibox = {
    # \`nix path-info -S\` of
    # nixosConfigurations.spotibox.config.system.build.toplevel.
    measuredBytes = $total;

    # CI fails above this: the measurement plus ${headroom_percent}% of headroom.
    maxBytes = $max;

    # What the numbers above were measured against.
    nixosVersion = "$version";
  };
}
EOF

  echo "recorded $(human "$total") (budget $(human "$max")) in $budget_file"
}

case "${1:-}" in
  report)   shift; cmd_report "$@" ;;
  diff)     shift; cmd_diff "$@" ;;
  why)      shift; cmd_why "$@" ;;
  roots)    shift; cmd_roots "$@" ;;
  check)    shift; cmd_check "$@" ;;
  baseline) shift; cmd_baseline "$@" ;;
  image-channel) shift; cmd_image_channel "$@" ;;
  *)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
