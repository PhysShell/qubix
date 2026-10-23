#!/usr/bin/env bash
# Run one scanbox job: tools/scanbox-run.sh <job-dir> <out-dir> [timeout-seconds]
#
# <job-dir> must contain run.sh; the guest sees it read-only at /job.
# <out-dir> is created if missing; the guest writes to it at /out.
# The VM gets a fresh system disk every time.  Exit status is the job's
# (from <out-dir>/exit-code), 124 on timeout, 125 if the VM never reported.
set -euo pipefail

job=$(realpath "${1:?job dir}")
out=$(realpath -m "${2:?out dir}")
timeout_s=${3:-14400}
here=$(cd "$(dirname "$0")/.." && pwd)

[ -f "$job/run.sh" ] || { echo "no run.sh in $job" >&2; exit 2; }
[ -w /dev/kvm ] || { echo "/dev/kvm is not writable; scanbox needs KVM" >&2; exit 2; }
mkdir -p "$out"
rm -f "$out/exit-code"

vm=$(nix build --no-link --print-out-paths "$here#scanbox-vm")
state=$(mktemp -d "${TMPDIR:-/tmp}/scanbox.XXXXXX")
trap 'rm -rf "$state"' EXIT

export QUBIX_JOB="$job" QUBIX_OUT="$out"
export NIX_DISK_IMAGE="$state/scanbox.qcow2"
export TMPDIR="$state"

set +e
( cd "$state" && timeout --foreground "$timeout_s" "$vm/bin/run-scanbox-vm" ) </dev/null 2>&1 | tee "$out/console.log"
vm_rc=${PIPESTATUS[0]}
set -e

if [ "$vm_rc" = 124 ]; then echo "scanbox: timeout after ${timeout_s}s" >&2; exit 124; fi
[ -f "$out/exit-code" ] || { echo "scanbox: VM exited ($vm_rc) without an exit code" >&2; exit 125; }
exit "$(cat "$out/exit-code")"
