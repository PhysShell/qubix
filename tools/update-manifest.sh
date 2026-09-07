#!/usr/bin/env bash
# Regenerate manifest.json from Nix.  Nix stays the source of truth; the
# committed file exists so that Windows hosts without WSL can read it.
# CI fails when the committed file drifts from the Nix output.
set -euo pipefail
cd "$(dirname "$0")/.."

out=$(nix build --no-link --print-out-paths .#qubix-manifest-json)
cp --no-preserve=mode "$out" manifest.json
echo "manifest.json updated from $out"
