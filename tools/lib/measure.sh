# shellcheck shell=bash
# Sourced by tools/closure.sh and tools/telemetry.sh: how a build that is about
# to be measured gets built, and which store it is measured in.
#
# A recorded budget is a claim about the artifact, so the number in it has to
# be the one anybody else gets from the same commit.  Nix makes that true for a
# build it isolates, and only for that, which this repository learned the
# expensive way.  Both budgets were once recorded on a builder with the sandbox
# off, and came out 59,024 bytes under what every CI run measures for the very
# same derivation.  nixpkgs' font cache derivation runs fc-cache with
# /var/cache/fontconfig ahead of $out among its cache directories: a sandboxed
# build cannot write there and falls through to $out, an unsandboxed one
# running as root can - so the cache went to the builder's /var and the image
# kept an empty one, 65,064 bytes short.  hwdb.bin records the files it was
# compiled from by their full path, and outside the sandbox that path starts
# with a random 38-character build directory instead of /build: 33 files, 32
# bytes each, 1,056 bytes.  The kernel's modules and the initrd built from them
# made up the rest.
#
# Two rules follow, and the functions below are how they are kept.
#
#   Every build here runs in the sandbox or fails.  `--option sandbox true`
#   alone is not that: sandbox-fallback defaults to true, and it builds
#   without isolation, quietly, wherever the kernel will not set one up.
#
#   A recording measures in a store of its own, created empty for it.  Nix
#   never rebuilds an output it already has, so forcing the sandbox on a
#   machine whose store was filled without one hands back the same polluted
#   paths - the empty font cache above comes back in 50 ms.  A fresh store
#   holds only what carries a trusted signature or its own content hash, and
#   what was built right there, in the sandbox.

# Empty until measure_in_fresh_store: the machine's own store.
measure_root=
measure_store_args=()

nix_build() {
  nix build "${measure_store_args[@]}" \
    --option sandbox true --option sandbox-fallback false "$@"
}

nix_path_info() {
  nix path-info "${measure_store_args[@]}" "$@"
}

# Where a store path of the measurement store is on this machine's disk.
host_path() {
  printf '%s%s\n' "$measure_root" "$1"
}

# Points every function above at a new, empty store under $TMPDIR, deleted
# again when the script exits.  Several GiB for an image, which is the price
# of a number that does not depend on where it was taken.
#
# It fills from the machine's substituters - so the kernel comes from the
# physshell cache wherever that is configured, as it does in CI - and from
# the machine's own store, which is safe to draw on for exactly the reason
# the store it replaces was not: a substitute has to carry a signature by a
# trusted key, or be content-addressed and match its hash.  What this machine
# built itself carries neither, so the empty font cache is refused and built
# again in the sandbox, while the flake's pinned sources and everything that
# came off a cache are copied over instead of fetched again.
measure_in_fresh_store() {
  measure_root=$(mktemp -d -t qubix-measure.XXXXXX)
  measure_store_args=(--store "local?root=$measure_root"
                      --option extra-substituters auto)
  trap measure_cleanup EXIT
  echo "measuring in a fresh store: $measure_root" >&2
}

measure_cleanup() {
  [ -n "$measure_root" ] || return 0
  # Store paths are read-only, directories included.
  chmod -R u+w -- "$measure_root" 2>/dev/null || true
  rm -rf -- "${measure_root:?}"
}

# The sandbox, proven from the inside before anything is measured: a fresh
# derivation, in the store and with the settings the measurement uses, that
# fails unless it sees nothing of the machine it runs on.  That also catches
# the ways the options above can fail to bite - a daemon that ignores them
# from an untrusted user, extra-sandbox-paths that put the host back in.
require_sandbox() {
  local log
  if ! log=$(nix_build --no-link --impure \
      --file "$(dirname "${BASH_SOURCE[0]}")/sandbox-probe.nix" \
      --argstr nonce "$(date +%s%N)-$$" 2>&1); then
    {
      printf '%s\n' "$log" | sed 's/^/  /'
      echo "refusing to measure: a build here is not isolated from this machine."
      echo "Whatever it can see can end up in the image, so a number taken here"
      echo "is this machine's, not the commit's.  Measure where the sandbox is"
      echo "Nix's own and nothing else - in CI, if nowhere else."
    } >&2
    exit 1
  fi
  echo "sandbox: a probe build ran and saw nothing of this machine" >&2
}

# The commit being measured, with -dirty when the tree differs from it: a
# measurement of uncommitted work names its parent commit and would otherwise
# claim a provenance it does not have.
measure_rev() {
  local rev
  rev=$(git rev-parse HEAD 2>/dev/null || echo unknown)
  git diff --quiet HEAD 2>/dev/null || rev="$rev-dirty"
  printf '%s\n' "$rev"
}

# A budget answers "measured on exactly what?", and a -dirty rev answers "on
# roughly this".  So recording one from a tree that is not a commit is refused,
# before the builds rather than after them; --allow-dirty exists for
# experiments, and the rev it records still says -dirty.
refuse_unless_commit() {
  local rev="$1" file="$2"
  case "$rev" in
    *-dirty|unknown)
      {
        echo "$(basename "$0"): refusing to record $file from a tree that is not a commit ($rev)."
        echo "Commit first, so the budget names the exact source it was measured on."
        echo "(--allow-dirty records anyway, and the rev says so.)"
      } >&2
      exit 1 ;;
  esac
}
