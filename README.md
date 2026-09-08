# Qubix

Idea is to be able to easy declare persistent NixOS VM's which are also perfectly safe if they get deleted for isolation purposes.

Quickstory:

The root originated from me wishing to isolate some potential bloatware like Spotify desktop app when having requirements as follows: `use only Windows as host, be easy to [re-]install, look like as much seamlessly to host as possible`. Nested VM sounded like too much messing around, Windows Sandbox is disposable by design so that I had to relogin everty reboot which is inconvenient. I reluctantly continued using Spotify in browser.

Once upon a time, not so late after that idea came to my mind, I was doomscrolling GitHub and starring cool repos as usual, all went well, and here was no sign of trouble ahead until I got to see [nixos-generators](https://github.com/nix-community/nixos-generators)...

That looked inspiring and challenging - and felt really good! - which is rare for me due to free time issues. So, my tiny bit of experience in Nix(OS), some freshy motivation, and it all start interfering, that turned into [spotibox](https://gist.github.com/PhysShell/990d150c28f587f3093d36f6e7a9e8a9).

Name `Qubix` is a Qubes OS + Nix which is so obvious but fancy that I couldn't resist naming it like this, although the project neither affiliated nor tries to compete with Qubes OS in any way. More like, it only serves me as a fun thingy to try and it's been choosen after the mind lightning effect after I dug into Qubes OS compartmentalization philosophy. Might call it a tribute if you want. And unfortunately it looks like the only way QOS intended to work is to have it as your bare-metal host.


Qubix is a small declarative appliance factory for Windows-hosted, Hyper-V-based
NixOS VMs. The first appliance, `spotibox`, is a minimal Spotify VM with Openbox,
xrdp and the PulseAudio audio path that worked in the prototype.

The loop, from the Windows side, is one click:

```text
machines/*.nix + profiles/*.nix          (source of truth, Nix)
  -> GitHub Actions builds the Hyper-V VHDX + home-disk seed
  -> tools\qubix-up.cmd downloads them, creates the VM once, starts it
  -> mstsc opens with Spotify filling the window
```

WSL is not required on the host. It stays available as the developer loop
(`-ImageSource wsl`) for building images locally.

## What You Get

- A modular NixOS configuration for `spotibox`.
- A Hyper-V Generation 2 VHDX built through `nixos-generators`.
- A **persistent home disk**: `/home` lives on its own VHDX, so replacing the
  system image never logs you out of Spotify.
- A Spotify kiosk session: xrdp starts Openbox + Spotify, the Spotify window is
  undecorated and maximised, quitting Spotify closes the RDP window.
- A Nix-generated JSON manifest (`manifest.json`, committed, CI-checked)
  consumed by the Windows controller without WSL.
- `tools/qubixctl.ps1`, an idempotent controller (`up` is the default), and
  `tools/qubix-up.cmd`, the double-click launcher that elevates itself.
- GitHub Actions: `ci` (flake check, manifest drift, PowerShell lint + unit
  checks) and `release` (builds and attaches the images to a tagged release).
- A stable xrdp audio baseline using PulseAudio, not PipeWire, and xrdp built
  without the MP3/Opus encoders so that mstsc negotiates PCM and actually
  plays it (see *Why PCM-only audio*).
- Separate `user` and `rdp` accounts (pinned UIDs) to avoid session
  cross-contamination.
- A NixOS smoke test for users, xrdp, Spotify, Openbox, Avahi and the kiosk
  session wiring.

## Quick Start (Windows, No WSL)

Once: enable Hyper-V from an elevated PowerShell and reboot.

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
```

Then clone the repository to a normal Windows path and double-click
`tools\qubix-up.cmd`. It asks for elevation and runs `qubixctl -Command up`:

1. reads `manifest.json`;
2. resolves the latest GitHub release, downloads `spotibox.vhdx.gz`,
   `spotibox-home.vhdx.gz` and `SHA256SUMS` into `C:\HyperV\Qubix\images\`,
   verifies and unpacks them (cached per release tag);
3. creates `qubix-spotibox` on first run only: system disk from the image,
   home disk seeded once, NAT switch `spotibox-nat` with a static address;
4. starts the VM, waits for port 3389, writes `qubix-spotibox.rdp`, stores the
   lab credential in Windows Credential Manager and launches `mstsc`.

Every later click is the same command: the VM already exists, so it just
starts (or resumes) and opens the window. Spotify comes up maximised inside it.

From a console the same thing is:

```powershell
.\tools\qubixctl.cmd                       # up spotibox
.\tools\qubixctl.cmd -Command status
.\tools\qubixctl.cmd -Command stop
```

### Commands

| Command    | What it does                                                                 |
|------------|------------------------------------------------------------------------------|
| `up`       | create-if-missing, start, wait for RDP, connect (default)                    |
| `connect`  | open the RDP window for a running VM                                         |
| `start`    | start / resume the VM                                                        |
| `stop`     | graceful shutdown                                                            |
| `status`   | VM state, adapters, disks, address, installed image version, cached images   |
| `recreate` | replace the system disk with fresh images; **the home disk is kept**         |
| `destroy`  | remove VM + system disk; `-Purge` also deletes the home disk                 |
| `fetch`    | download release images into the cache without touching the VM              |
| `build`    | build images in WSL (developer path)                                         |
| `gc`       | report unused cached images; `-Force` deletes them                           |
| `manifest` | print the resolved machine config                                            |

Useful switches: `-Release v0.2.0` (pin a release), `-VmRoot D:\vms`,
`-SwitchName`, `-Address 192.168.250.10`, `-NoConnect`, `-NoSavedCredential`,
`-TimeoutSeconds 600`.

### Where Images Come From

| `-ImageSource` | Source                                                                | Needs      |
|----------------|-----------------------------------------------------------------------|------------|
| `auto`         | `-ImagePath` if given, otherwise `release` (default)                  |            |
| `release`      | GitHub release assets of `PhysShell/qubix` (`latest` or `-Release`)   | internet   |
| `wsl`          | `nix build` inside WSL; manifest regenerated from Nix on the fly      | WSL + Nix  |
| `file`         | `-ImagePath <x.vhdx|.gz>` plus `-HomeImagePath` for a first-time home | files      |

Release downloads use plain `https://github.com/<repo>/releases/...` URLs, so a
public repository needs no token. Private repositories are not supported by the
`release` source yet; use `fetch` from a machine that can reach the assets, or
the `wsl` / `file` sources.

### Reclaiming Disk Space

Every `up` or `recreate` from a `.gz` leaves an unpacked copy in the cache, and
release downloads keep one directory per tag. `gc` clears what is no longer
needed:

```bash
qubixctl -Command gc            # dry run: what would go, and how much
qubixctl -Command gc -Force     # delete it
qubixctl -Command gc -Force -All  # drop the installed image's cache as well
```

Nothing is deleted without `-Force`, and the dry run needs no elevation. The
cache directory matching `image-version.txt` is kept by default, since
re-fetching a release means downloading the assets again; `-All` is the
`nix-collect-garbage -d` of this command. `local/` is always dropped - it only
ever holds a copy unpacked from a file the caller already has.

The VM directory is never touched: not the home disk, not the live system disk.
Images staged by hand under `vmRoot` (for `-ImageSource file`) are **reported
but never deleted** - tidying up after the controller is one thing, deleting
what a person put there is another:

```text
Disk images under C:\HyperV\Qubix that qubixctl did not create (18.67 GB):
  C:\HyperV\Qubix\src\spotibox-kb.vhdx  (5.57 GB)
  ...
These were staged by hand; delete them yourself if they are no longer needed.
```

## Persistence Model

```text
C:\HyperV\Qubix\
  images\spotibox\<tag>\        unpacked release assets (cache, safe to delete)
  qubix-spotibox\
    qubix-spotibox.vhdx         SYSTEM disk  = Nix artifact, replaced by recreate
    qubix-spotibox-home.vhdx    HOME disk    = the only state, never replaced
    qubix-spotibox.rdp          generated connection file
    image-version.txt           release tag / build id of the system disk
```

- The system disk is rebuilt from Nix; nothing on it is worth keeping.
- `/home` is mounted from the disk labelled `qubix-home` and is required for
  boot (`profiles/storage/persistent-home.nix`). A missing home disk stops the
  boot loudly instead of silently handing you an empty home.
- `recreate` deletes only the system disk. Spotify stays logged in.
- Hyper-V checkpoints are disabled on the VM: they would fork the home disk
  into `.avhdx` chains the controller cannot reason about.
- User IDs are pinned (`user` = 1000, `rdp` = 1001) so a persistent home never
  changes owner when the user list changes.

## Continuous Integration

`ci` runs on pull requests, on pushes to `main`, and on manual dispatch. It
does **not** run on a push to a feature branch, so work on a branch stays
unchecked until a PR exists - open one early if you want the signal.

| Job | Runner | What it does |
| --- | --- | --- |
| `flake check, manifest sync, home seed` | ubuntu | `nix flake check`, fails on `manifest.json` drift, builds the home seed |
| `controller lint + unit checks (powershell)` | windows | unit checks under Windows PowerShell 5.1, the shell `qubix-up.cmd` actually uses |
| `controller lint + unit checks (pwsh)` | windows | the same checks under pwsh 7, plus PSScriptAnalyzer |

Driving it from the terminal with the GitHub CLI:

```bash
gh run list --limit 10                 # recent runs, newest first
gh run watch                           # follow the run for the current branch
gh run view <run-id> --log-failed      # only the failing steps
gh run rerun <run-id> --failed         # retry just the failed jobs
gh workflow run ci.yml --ref <branch>  # manual dispatch
gh pr checks <pr>                      # per-check status for a PR
```

A run that fails in 0s with no jobs, and a workflow listed under its file path
instead of its `name:`, means GitHub could not compile the YAML - the run log
is empty in that case, so lint locally instead:

```bash
nix run nixpkgs#actionlint
```

`actionlint` catches the whole class of errors GitHub reports only as a failed
run, such as using a context where none is allowed.

## Publishing A Release

```bash
git tag v0.2.0
git push origin v0.2.0
```

The `release` workflow builds `.#spotibox-release` on GitHub Actions (KVM is
enabled on the runner so `make-disk-image` does not crawl through emulation),
checks every asset against the 2 GB GitHub limit and attaches:

```text
spotibox.vhdx.gz        system image (gzip, unpacked on Windows with .NET only)
spotibox-home.vhdx.gz   16 GiB dynamic ext4 seed, a few hundred KB compressed
manifest.json           the manifest the images were built with
SHA256SUMS
VERSION                 tag + commit
```

`workflow_dispatch` with an existing tag rebuilds and re-attaches the assets.

## Developer Loop (WSL)

From Linux/WSL, the usual Nix commands still work:

```bash
nix build .#spotibox-vhdx          # or just `nix build`
nix build .#spotibox-home-vhdx
nix build .#spotibox-release       # what CI publishes
nix flake check --no-build
```

Whenever `machines/*.nix` or the manifest logic changes, regenerate the
committed manifest (CI fails on drift):

```bash
tools/update-manifest.sh
```

To test a local build on the Windows side without publishing a release:

```powershell
# repo lives in WSL:   assign the UNC path, do not cd into it
$Qubix = "\\wsl.localhost\NixOS\home\nixos\Documents\repos\qubix"
& "$Qubix\tools\qubixctl.cmd" -Command recreate -ImageSource wsl
```

With `-ImageSource wsl` the controller derives the distro and Linux path from
the UNC path (override with `-WslDistro` / `-RepoLinuxPath`), regenerates the
manifest from Nix, builds both images and copies them out of the store.

The `.cmd` wrappers run PowerShell with a process-scoped
`-ExecutionPolicy Bypass`, which also sidesteps Windows treating scripts under
`\\wsl.localhost\...` as unsigned remote files. `cmd.exe` cannot use a UNC path
as its working directory, so the wrappers `pushd` to a temporary drive letter.

## Networking

`machines/spotibox.nix` declares a static address:

```nix
qubix.network = {
  staticIp = "192.168.250.10";
  gateway  = "192.168.250.1";
};
```

The manifest derives `gatewayIp` and `natSwitchSubnet` from it, and `qubixctl`
creates an Internal Hyper-V switch `spotibox-nat`, assigns the gateway address
to the host `vEthernet` adapter and adds a `NetNat` rule. All three steps are
idempotent. Because the image and the manifest come from the same machine file,
they cannot disagree about the address.

Remove `qubix.network.staticIp` (set it to `null`) to fall back to DHCP on
`Default Switch`. The controller then asks Hyper-V for the address the guest
reported (`hv_kvp_daemon`) and falls back to `spotibox.local` via Avahi/mDNS.

Windows allows a single `NetNat` instance per host. If another NAT network
already exists (Docker, a lab switch), reuse it or switch spotibox to DHCP.

## Validation

```bash
nix flake check --no-build                                   # evaluates every system and the test
nix build .#checks.x86_64-linux.spotibox-basic               # boots the appliance in QEMU
pwsh ./tests/qubixctl.Tests.ps1                              # controller unit checks
```

Manual acceptance on Windows:

1. Double-click `tools\qubix-up.cmd`; Hyper-V shows `qubix-spotibox` running.
2. The RDP window opens as `rdp` with Spotify maximised and undecorated.
3. Audio plays through the host; `pavucontrol` (via an `xterm` from the Hyper-V
   console, user `user`) shows the xrdp sink.
4. Log into Spotify, run `qubixctl -Command recreate`, click again: still
   logged in.
5. Quit Spotify: the RDP window closes.

## Design Notes

### Why not run Spotify from WSL instead?

WSLg would give a real native window with audio for free, but WSL is not an
isolation boundary: every distro shares one utility VM, and interop, automount
and the Windows PATH are on by default. Turning those off per distro reduces
exposure; it does not turn WSL into a VM. Since isolation is the whole point,
the appliance stays a Hyper-V VM and the "native window" is approximated by a
kiosk session in a windowed RDP client.

### Why not App Sandbox / HCS?

[App Sandbox](https://github.com/jamesstringer90/appsandbox) (the successor of
the archived Easy-GPU-PV) is the interesting future backend: HCS-based VMs
without the Hyper-V role, GPU-PV, snapshots, a headless API. Today it documents
Windows 11 and Ubuntu guests built from ISO, not arbitrary images such as a
NixOS VHDX, its storage path is not configurable and the daemon owns the VM
lifecycle. Nothing in it helps a Spotify appliance that Hyper-V already runs.
The manifest is deliberately backend-neutral (`gpu`, `network`, disks) so a
second backend can be added without touching the Nix side.

### Why not Ansible for Windows?

Ansible needs a Linux control node, which on this host means WSL, the very
dependency this change removes from the runtime path. The Windows-side work
here is a few Hyper-V cmdlets; a 20 KB PowerShell script with unit checks is
the right size for it.

### Why no GPU-PV?

Spotify does not need it, and GPU-PV for a Linux guest on Hyper-V means the
out-of-tree `dxgkrnl` module plus host driver files in the guest, a rabbit hole
with a Windows-update-shaped trapdoor. Off by design for this appliance.

### Why VHDX Instead Of ISO Autoinstall

The old prototype used an ISO that booted, partitioned `/dev/sda`, installed
NixOS and rebooted. That works, but it keeps the slowest and most fragile part of
the loop: installing an OS inside a VM every time.

Qubix builds the final Hyper-V VHDX directly from Nix. Hyper-V then only has
to boot a ready disk.

### Why PulseAudio+xrdp

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

### Keyboard groups in remote sessions

xrdp pins the guest's XKB layout to whatever the client had **at connect time**
and never revisits it: RDP carries the layout once, in the Client Info PDU, and
sends bare scancodes afterwards. Switching the layout on the Windows side does
nothing in the guest until you reconnect - which reads as "the VM ignores my
keyboard" and is really "the VM was told once and never again".

`profiles/remote/xrdp.nix` wraps the session so that, once xrdp has applied the
client's layout, a Latin group is added next to it plus a toggle. The list is
not hardcoded: whatever the client negotiated is what gets a companion group, so
a German client gets `us,de` and a Russian one `us,ru`, while a Latin-only
client keeps its single group and notices nothing. Tunable through
`qubix.keyboard.latinGroup` and `qubix.keyboard.toggle`.

Two caveats worth knowing:

- The default toggle is `grp:win_space_toggle`, and **Win keys only reach the
  guest when mstsc runs full screen** (`Ctrl+Alt+Break` toggles that). In a
  windowed session Windows keeps Win+Space for itself.
- On *reconnect* to an existing session the wrapper does not run again, so the
  groups can collapse back to the client's single layout. Fixing that properly
  belongs in xrdp, not here.

### Why PCM-only audio

nixpkgs builds xrdp with `--enable-mp3lame` and `--enable-opus`. With those
available, Windows' `mstsc` negotiates `WAVE_FORMAT_MPEGLAYER3` and then plays
nothing at all, while every diagnostic inside the guest looks perfectly
healthy: `xrdp-sink` is the default sink, it is not muted, it sits at 100%, it
moves between IDLE and RUNNING in time with the track, chansrv accepts the
socket and logs `round trip time 0`. Only the host is silent, and the Windows
volume mixer shows the mstsc slider with no level on it. See
[neutrinolabs/xrdp#965](https://github.com/neutrinolabs/xrdp/issues/965).

`profiles/audio/pulseaudio-xrdp.nix` therefore drops both encoders, which
leaves PCM as the only negotiable format. PCM is ~176 kB/s - irrelevant next to
the video channel.

The override has to be a `nixpkgs.overlays` entry rather than the obvious
`services.xrdp.package`. The NixOS module declares that option but then
hardcodes `pkgs.xrdp` in the `ExecStart` of both `xrdp.service` and
`xrdp-sesman.service`, so setting it rebuilds `confDir` only and the daemons
keep running the untouched build - the option silently does nothing. A fix is open
upstream as [nixpkgs#452303](https://github.com/NixOS/nixpkgs/pull/452303); when it
lands, this overlay can become a plain `services.xrdp.package` assignment.

### Nix-Generated JSON

Nix is the source of truth for the manifest. `manifest.json` is the output of
`nix build .#qubix-manifest-json`, committed so that a Windows host without WSL
can read it, and checked for drift by CI. With `-ImageSource wsl` the
controller regenerates it live instead of reading the file.

## Layout

```text
flake.nix                  packages, manifest, home seed, release bundle
manifest.json              generated by tools/update-manifest.sh, CI-checked
machines/
  spotibox.nix
  spotibox-debug.nix
modules/qubix-options.nix  qubix.* options (mode, gui, audio, app, session, homeDisk, network)
profiles/
  apps/spotify.nix         Spotify package, kiosk rc.xml, spotibox-session
  audio/pulseaudio-xrdp.nix
  gui/openbox.nix
  kernel/default.nix
  modes/debug.nix, prod.nix
  network/default.nix
  remote/xrdp.nix          xrdp server, session = qubix.session.command
  security/minimal.nix
  storage/persistent-home.nix
tools/
  qubixctl.ps1             controller
  qubixctl.cmd             console wrapper
  qubix-up.cmd             double-click launcher (elevates, runs `up`)
  update-manifest.sh
tests/
  spotibox-basic.nix       NixOS VM test
  qubixctl.Tests.ps1       controller unit checks
.github/workflows/
  ci.yml, release.yml
```

## TODO / Later Goals

- Spotify network lockdown via nftables, proxy or DNS allowlist.
- PipeWire + EasyEffects experiment once xrdp audio is understood.
- Hardening profile, possibly inspired by nix-mineral, applied carefully.
- Production image with fewer debug tools (drop `xterm` from prod).
- Kernel profile experiments: default/latest/hardened first, custom tiny kernel later.
- Hyper-V differencing disks for disposable runtime clones.
- Private-repository release downloads (token-authenticated asset URLs).
- Second backend behind the same manifest (App Sandbox / HCS) once it accepts
  custom images and a configurable storage path.
- `backend.microvm` for headless disposable sandboxes.
- `backend.nspawn` for trusted services.

## References

- nixos-generators: <https://github.com/nix-community/nixos-generators>
- Generating YAML files with Nix: <https://kokada.dev/blog/generating-yaml-files-with-nix/>
- App Sandbox: <https://github.com/jamesstringer90/appsandbox>
