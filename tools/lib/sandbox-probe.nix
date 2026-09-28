# The probe behind require_sandbox in tools/lib/measure.sh: a build that
# succeeds only if it cannot see the machine it runs on.
#
#   nix build --impure --file tools/lib/sandbox-probe.nix --argstr nonce "$RANDOM"
{ nonce }:
derivation {
  name = "qubix-sandbox-probe";
  system = builtins.currentSystem;

  # The static shell Nix itself mounts at /bin/sh in every Linux sandbox, and
  # nothing from nixpkgs: the probe has nothing to fetch or build before it
  # can answer, and it answers with shell builtins alone, since that busybox
  # carries no ls.
  builder = "/bin/sh";
  args = [ "-c" ''
    seen=
    for p in /* /.[!.]* /nix/*; do
      case "$p" in
        # What Nix's sandbox puts there itself, and globs that matched nothing.
        /bin|/build|/dev|/etc|/nix|/proc|/tmp|/nix/store) ;;
        '/*'|'/.[!.]*'|'/nix/*') ;;
        *) seen="$seen $p" ;;
      esac
    done
    # The sandbox gives every build a PID namespace of its own.
    [ "$$" = 1 ] || seen="$seen (and the builder is not PID 1)"
    if [ -n "$seen" ]; then
      echo "this build can see the host:$seen" >&2
      exit 1
    fi
    echo isolated > "$out"
  '' ];

  # Different on every run, so the probe is never already in the store.
  inherit nonce;
}
