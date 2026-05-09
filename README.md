# Qubix

Idea is to be able to easy declare persistent NixOS VM's which are also perfectly safe if they get deleted for isolation purposes.

Quickstory:

The root originated from me wishing to isolate some potential bloatware like Spotify desktop app when having requirements as follows: `use only Windows as host, be easy to [re-]install, look like as much seamlessly to host as possible`. Nested VM sounded like too much messing around, Windows Sandbox is disposable by design so that I had to relogin everty reboot which is inconvenient. I reluctantly continued using Spotify in browser.

Once upon a time, not so late after that idea came to my mind, I was doomscrolling GitHub and starring cool repos as usual, all went well, and here was no sign of trouble ahead until I got to see [nixos-generators](https://github.com/nix-community/nixos-generators)...

That looked inspiring and challenging - and felt really good! - which is rare for me due to free time issues. So, my tiny bit of experience in Nix(OS), some freshy motivation, and it all start interfering, that turned into [spotibox](https://gist.github.com/PhysShell/990d150c28f587f3093d36f6e7a9e8a9).

Name `Qubix` is a Qubes OS + Nix which is so obvious but fancy that I couldn't resist naming it like this, although the project neither affiliated nor tries to compete with Qubes OS in any way. More like, it only serves me as a fun thingy to try and it's been choosen after the mind lightning effect after I dug into Qubes OS compartmentalization philosophy. Might call it a tribute if you want. And unfortunately it looks like the only way QOS intended to work is to have it as your bare-metal host.


Qubix is a small declarative appliance factory for Windows-hosted, Hyper-V-based
NixOS VMs. The MVP builds one appliance, `spotibox`, as a minimal Spotify VM with
Openbox, xrdp and the PulseAudio audio path that worked in the prototype.


The goal is a fast local loop:

```text
Nix modules
  -> nixos-generators Hyper-V VHDX
  -> PowerShell recreates the Hyper-V VM
  -> mstsc connects to the appliance
```

## What The MVP Gives You

- A modular NixOS configuration for `spotibox`.
- A Hyper-V Generation 2 VHDX built through `nixos-generators`.
- A Nix-generated JSON manifest consumed by PowerShell.
- A Windows PowerShell controller, `tools/qubixctl.ps1`.
- A stable xrdp audio baseline using PulseAudio, not PipeWire.
- Separate `user` and `rdp` accounts to avoid session cross-contamination.
- A basic NixOS smoke test for users, xrdp, Spotify, Openbox and Avahi.

## Layout

```text
flake.nix
machines/
  spotibox.nix
  spotibox-debug.nix
profiles/
  audio/pulseaudio-xrdp.nix
  apps/spotify.nix
  gui/openbox.nix
  kernel/default.nix
  modes/debug.nix
  modes/prod.nix
  security/minimal.nix
tools/
  qubixctl.ps1
tests/
  spotibox-basic.nix
```

## Build The Image

From Linux/WSL:

```bash
nix build .#spotibox-vhdx
```

The default package is also `spotibox-vhdx`, so this works too:

```bash
nix build
```

The generated manifest is available as a build artifact:

```bash
nix build .#qubix-manifest-json
cat result
```

`result` is a symlink to the JSON file in the Nix store.  The PowerShell
controller builds and reads the same artifact at runtime — you do not need to
build it manually.

## Recreate The Hyper-V VM

Run PowerShell from Windows. Mutating Hyper-V commands must be run from an
elevated PowerShell session.

```powershell
Set-Location $HOME
$Qubix = "\\wsl.localhost\NixOS\home\nixos\Documents\repos\qubix"

& "$Qubix\tools\qubixctl.cmd" -Command recreate -Machine spotibox
```

`recreate` builds the Nix image and recreates the VM in one step.

The `.cmd` wrapper runs the PowerShell script with process-scoped
`-ExecutionPolicy Bypass`. This avoids changing your global execution policy and
works around Windows treating scripts under `\\wsl.localhost\...` as unsigned
remote files. Keep the PowerShell working directory on a normal Windows path
when invoking the wrapper: `cmd.exe` cannot use a UNC path as its current
directory and otherwise falls back to `C:\Windows`. In other words, assign the
UNC path to `$Qubix`, but do not `cd` into it.

The controller defaults to:

- WSL distro: `NixOS`
- Linux repo path: `/home/nixos/Documents/repos/qubix`
- Hyper-V switch: `Default Switch`
- VM name: `qubix-spotibox`
- VM root: `C:\HyperV\Qubix`

Override them when needed:

```powershell
& "$Qubix\tools\qubixctl.cmd" `
  -Command recreate `
  -Machine spotibox `
  -WslDistro NixOS `
  -RepoLinuxPath /home/nixos/Documents/repos/qubix `
  -VmRoot C:\HyperV\Qubix `
  -SwitchName "Default Switch"
```

Other commands:

```powershell
& "$Qubix\tools\qubixctl.cmd" -Command build    # run nix build only, skip VM
& "$Qubix\tools\qubixctl.cmd" -Command status
& "$Qubix\tools\qubixctl.cmd" -Command start
& "$Qubix\tools\qubixctl.cmd" -Command stop
& "$Qubix\tools\qubixctl.cmd" -Command destroy
& "$Qubix\tools\qubixctl.cmd" -Command mstsc
```

`mstsc` defaults to `spotibox.local`. If name resolution fails, pass an address:

```powershell
& "$Qubix\tools\qubixctl.cmd" -Command mstsc -Address 192.168.192.121
```

## Why VHDX Instead Of ISO Autoinstall

The old prototype used an ISO that booted, partitioned `/dev/sda`, installed
NixOS and rebooted. That works, but it keeps the slowest and most fragile part of
the loop: installing an OS inside a VM every time.

Qubix MVP builds the final Hyper-V VHDX directly from Nix. Hyper-V then only has
to boot a ready disk.

## Why PulseAudio+xrdp

The prototype found a very specific failure mode: Hyper-V enhanced sessions and
mstsc sessions under the same Unix user can mix `DISPLAY`,
`DBUS_SESSION_BUS_ADDRESS` and PulseAudio state. In that broken state,
`pavucontrol` launched from mstsc may open in the Hyper-V session.

The stable baseline is:

```text
Hyper-V console -> user
mstsc/xrdp      -> rdp
xrdp audio     -> PulseAudio xrdp modules
PipeWire       -> disabled
```

EasyEffects is intentionally not the active DSP baseline here. It is
PipeWire-oriented, while this xrdp audio path expects PulseAudio.

## Connecting To The Appliance

### Default: mDNS (recommended for most cases)

The default manifest uses Hyper-V `Default Switch` with DHCP.  The IP address
may change after reboot, but Avahi mDNS lets you connect by name:

```powershell
.\tools\qubixctl.cmd -Command mstsc   # resolves spotibox.local
```

If `spotibox.local` does not resolve, use `status` or Hyper-V Manager to find the
current IP and pass it with `-Address`.

### Optional: Static IP with a Dedicated NAT Switch

For a stable address that survives reboots, declare a static IP in both the
NixOS machine config and the flake manifest.

Edit **`machines/spotibox.nix`** only — the manifest derives the values automatically:

```nix
qubix.network = {
  staticIp = "192.168.250.10";
  gateway  = "192.168.250.1";
};
```

Then **recreate** as usual:

```powershell
.\tools\qubixctl.cmd -Command recreate -Machine spotibox
```

`qubixctl` automatically creates an Internal Hyper-V switch (`spotibox-nat`),
assigns the gateway IP to the host vEthernet adapter, and creates a `NetNat`
rule so the VM can reach the internet.  All three steps are idempotent — safe
to re-run on every recreate.

Connect by fixed IP:

```powershell
.\tools\qubixctl.cmd -Command mstsc -Address 192.168.250.10
```

> **Note:** the NixOS image and the manifest must declare the same address.
> Qubix does not enforce this automatically — if they diverge the VM will boot
> with the wrong IP for the switch it is attached to.

## Validation

Evaluate the flake:

```bash
nix flake check --no-build
```

Run the full smoke test when you are ready to build test VMs:

```bash
nix build .#checks.x86_64-linux.spotibox-basic
```

Manual acceptance:

1. `.\tools\qubixctl.cmd -Command recreate -Machine spotibox`
2. Confirm Hyper-V has a running `qubix-spotibox`.
3. Connect with mstsc as `rdp` / `1234`.
4. Start `pavucontrol` in the RDP session and confirm the window appears there.
5. Start Spotify manually and confirm audio routes through RDP.

## Nix-Generated JSON And Future YAML

Nix is the source of truth for the manifest.  `qubixctl` builds the
`qubix-manifest-json` derivation at startup, reads the resulting store path,
and parses the JSON — no manually maintained config file.

YAML can be generated later as a human-facing artifact using the same pattern:
describe structured data in Nix, emit JSON with `builtins.toJSON`, then convert
JSON to YAML with a tool such as `yj`.

## TODO / Later Goals

- Spotify network lockdown via nftables, proxy or DNS allowlist.
- Stable custom Hyper-V NAT switch.
- PipeWire + EasyEffects experiment once xrdp audio is understood.
- Hardening profile, possibly inspired by nix-mineral, applied carefully.
- Production image with fewer debug tools.
- Kernel profile experiments: default/latest/hardened first, custom tiny kernel later.
- Hyper-V differencing disks for disposable runtime clones.
- Optional Nix-generated YAML artifact for human-facing config/docs.
- `backend.microvm` for headless disposable sandboxes.
- `backend.nspawn` for trusted services.

## References

- nixos-generators: <https://github.com/nix-community/nixos-generators>
- Generating YAML files with Nix: <https://kokada.dev/blog/generating-yaml-files-with-nix/>
