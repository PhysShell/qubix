#!/usr/bin/env bash
# Cold-boot a built VHDX the way firmware does, not the way a test driver does.
#
#   tools/cold-boot.sh [ATTR]     default: spotibox-vhdx
#
# The NixOS VM tests boot a system with -kernel/-initrd, which skips the ESP,
# the boot loader and the entry it wrote.  That is exactly the part
# profiles/modes/prod.nix replaces: production installs systemd-boot from a
# shell script instead of NixOS's Python one, to keep Nix out of the image.
# Nothing short of letting firmware find BOOTX64.EFI proves that still works.
#
# OVMF is the same firmware class as a Hyper-V generation 2 VM with Secure Boot
# off, which is how tools/qubixctl.ps1 creates the machine.  The home seed is
# attached as a second disk because the initrd waits for its label and drops to
# emergency mode without it - the way this script's first version did.
#
# Success is an RDP reply from the guest's static address: everything from the
# firmware through the boot loader, the root filesystem, the network and
# xrdp-sesman had to work to produce it.  Takes about ten minutes without KVM.
set -euo pipefail
cd "$(dirname "$0")/.."

attr="${1:-spotibox-vhdx}"
port="${QUBIX_COLD_BOOT_PORT:-13389}"
work=$(mktemp -d)
trap 'rm -rf "$work"; [ -n "${qemu_pid:-}" ] && kill "$qemu_pid" 2>/dev/null || true' EXIT

echo "building $attr and the home seed..."
system=$(nix build --no-link --print-out-paths ".#$attr")
home=$(nix build --no-link --print-out-paths ".#spotibox-home-vhdx")
vhdx=$(find -L "$system" -name '*.vhdx' -print -quit)
test -n "$vhdx" || { echo "no .vhdx in $system" >&2; exit 1; }

read -r ovmf qemu < <(nix build --no-link --print-out-paths \
  --impure --expr 'let p = (builtins.getFlake (toString ./.)).nixosConfigurations.spotibox.pkgs;
                   in [ p.OVMF.fd p.qemu_kvm ]' | tr '\n' ' ')

cp "$ovmf/FV/OVMF_VARS.fd" "$work/vars.fd"
chmod +w "$work/vars.fd"

# snapshot=on keeps both images read-only; the store copies stay untouched.
"$qemu/bin/qemu-system-x86_64" \
  -machine q35,accel=kvm:tcg -cpu max -m 2048 -smp 2 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$ovmf/FV/OVMF_CODE.fd" \
  -drive if=pflash,format=raw,unit=1,file="$work/vars.fd" \
  -drive file="$vhdx",format=vhdx,if=none,id=disk0,snapshot=on \
  -device ahci,id=ahci -device ide-hd,drive=disk0,bus=ahci.0 \
  -drive file="$home",format=vhdx,if=none,id=disk1,snapshot=on \
  -device ide-hd,drive=disk1,bus=ahci.1 \
  -netdev "user,id=n0,net=192.168.250.0/24,host=192.168.250.1,hostfwd=tcp::$port-192.168.250.10:3389" \
  -device virtio-net-pci,netdev=n0 \
  -vga std -display none -no-reboot \
  -qmp "unix:$work/qmp,server=on,wait=off" \
  -serial "file:$work/serial.log" &
qemu_pid=$!

# The forwarded socket accepts a connection whether or not the guest is up, so
# only an answer to a real X.224 connection request counts.
probe() {
  python3 - "$port" <<'PY'
import binascii, socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.settimeout(8)
s.sendall(binascii.unhexlify("030000130ee000000000000100080003000000"))
sys.exit(0 if s.recv(64)[:2] == b"\x03\x00" else 1)
PY
}

for i in $(seq 1 60); do
  sleep 20
  if probe 2>/dev/null; then
    echo "ok: xrdp answered after ~$((i * 20))s"
    sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$work/serial.log" | tr -d '\000' | tail -3
    exit 0
  fi
done

echo "FAIL: no RDP reply in 20 minutes.  Console:" >&2
python3 - "$work/qmp" "$work/console.ppm" <<'PY' >&2 || true
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rwb")
f.readline(); f.write(b'{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
f.write(json.dumps({"execute": "screendump",
                    "arguments": {"filename": sys.argv[2]}}).encode() + b"\n")
f.flush(); f.readline()
PY
cp "$work/console.ppm" ./cold-boot-console.ppm 2>/dev/null &&
  echo "wrote ./cold-boot-console.ppm" >&2
exit 1
