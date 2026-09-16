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
  session wiring - and for what the production image must *not* contain.
- A production/debug split that is enforced rather than aspirational:
  `qubix.mode` decides, `tests/appliance-split.nix` fails the build when a
  debugging tool reappears in the appliance, and `tools/closure.sh` holds the
  production image to a closure budget in CI. That took 2.2 GiB (57%) out of
  the image; see *Closure Budget*.

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
| `production closure budget` | ubuntu | builds `system.build.toplevel`, fails when the appliance grows past `tests/closure-budget.nix` or starts carrying a nixpkgs channel again |
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
nix flake check --no-build                                   # every system, both VM tests, the prod/debug split
nix build .#checks.x86_64-linux.spotibox-basic               # boots the appliance in QEMU
nix build .#checks.x86_64-linux.spotibox-xrdp-session        # starts a real xrdp session in it
tools/closure.sh report                                      # what the production image is made of
tools/closure.sh diff                                        # what the debug image adds on top of it
tools/closure.sh why cups                                    # who is still holding on to a store path
tools/closure.sh check                                       # the CI closure gate, locally
pwsh ./tests/qubixctl.Tests.ps1                              # controller unit checks
```

Manual acceptance on Windows:

1. Double-click `tools\qubix-up.cmd`; Hyper-V shows `qubix-spotibox` running.
2. The RDP window opens as `rdp` with Spotify maximised and undecorated.
3. Audio plays through the host. The production image has neither a mixer nor
   a terminal any more: to look at the xrdp sink, build `spotibox-debug`, which
   keeps `pavucontrol`, an `xterm` and ssh.
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

### Closure Budget

The VHDX is not a filesystem somebody installed packages into. It is the
closure of `system.build.toplevel` with a partition table around it: a package
ships because something in the system still refers to it. That is why
`nix-store --gc` inside the guest cannot make the image smaller, and why every
size decision here is a decision about *roots* - drop the reference and Nix
stops copying the path by itself.

`profiles/modes/prod.nix` is where the production image stops being a general
purpose NixOS box. Measured with `tools/closure.sh` against nixpkgs 25.11:

| Taken out of the production image | Closure |
| --- | --- |
| baseline, before any of this | 3.82 GiB |
| Perl, and the xdg-utils that was holding it | -57 MiB |
| the default font set, minus the two fonts this renders with | -36 MiB |
| desktop-session leftovers: XDG mime/icons/menus, nixos-icons, Avahi | -36 MiB |
| Mesa and the LLVM behind llvmpipe | -768 MiB |
| speech-dispatcher, espeak-ng, flite and 648 MiB of MBROLA voices | -699 MiB |
| ffmpeg's SDL output device, and everything behind it (see below) | -331 MiB |
| the nixpkgs sources pinned into `/etc/nix/registry.json` and `NIX_PATH` | -186 MiB |
| xterm, pavucontrol, alsa-utils, man-db, docs, installer tools, `environment.defaultPackages` | -160 MiB |
| the display-manager layer: LightDM, the NixOS xsession script, feh, Ghostscript | -84 MiB |
| an OpenSSH client, BIND's `host`, and the rest of `corePackages` | -38 MiB |
| the rest of NixOS's X server module (see below) | -10 MiB |
| **production total** | **1.47 GiB (-61.4%)**, 1024 store paths down to 666 |

Three of those were never asked for by anything in the appliance:

- `services/misc/graphical-desktop.nix` switches `services.speechd` on for any
  system with a graphical session - "default guessed conservatively", says the
  module - and speech-dispatcher pulls in a diphone voice corpus. Spotify does
  not talk to the user.
- Building a NixOS system from a flake pins the nixpkgs sources into the
  system-wide flake registry and `NIX_PATH`, so that `nix run nixpkgs#hello`
  works offline on the machine. The appliance runs no nix commands, and
  upstream documents the closure cost of leaving it on.
The font trim was checked the same way the rest of this branch was: by tracing
what the application actually opens. On the trimmed image Spotify opens
`DejaVuSans.ttf` and `NotoColorEmoji.ttf` - plus the rest of the DejaVu family
- and asks for nothing it cannot find. Removing six font packages is the kind
of change that fails visually rather than loudly, so "it still boots" would not
have been an answer.

- `hardware.graphics.enable` follows a graphical session around, and it
  installs Mesa with the LLVM that llvmpipe needs. Hyper-V exposes no GPU, and
  Spotify is a CEF application that carries its own renderer: traced through a
  full startup in a VM with the option off, it loads
  `share/spotify/libEGL.so`, `libGLESv2.so` and `libvulkan.so.1` - ANGLE over
  SwiftShader - puts its window on screen, and never mentions
  `/run/opengl-driver` once. Xorg keeps `libglvnd` and `mesa-libgbm`, which are
  separate packages and two orders of magnitude smaller.

A third one never reaches `toplevel` at all. `nixos/lib/make-disk-image.nix`
copies a whole nixpkgs source tree into the image as the root user's `nixos`
channel unless told otherwise, and the upstream Hyper-V module never tells it:
`copyChannel` defaults to true. `profiles/image/hyperv.nix` calls
make-disk-image itself with `copyChannel = false` for production images, taking
another ~186 MiB of Nix expressions out of the VHDX - a second copy of the tree
the registry was already pinning. `tools/closure.sh check` fails if it returns.

### The X Server Nobody Configures

The appliance runs X11, so `services.xserver.enable = true` looked like a load
bearing line. It was not. xrdp starts one X server per session, and it starts
it from its own `sesman.ini`, with a command line that nixpkgs bakes into the
xrdp package at build time:

    [Xorg]
    param=/nix/store/...-xorg-server-21.1.22/bin/Xorg
    param=-modulepath
    param=/nix/store/...-xorgxrdp-0.10.4/lib/xorg/modules,...
    param=-config
    param=/nix/store/...-xorgxrdp-0.10.4/etc/X11/xrdp/xorg.conf

NixOS's generated `/etc/X11/xorg.conf` is not in that list, and neither is
`display-manager.service`. The upstream module says so in one comment - "xrdp
can run X11 program even if `services.xserver.enable = false`" - and that is
the whole of the documentation. So production turns the module off, and what
leaves is the part of it that was only ever furniture for a desktop:

- the input driver stack: `xf86-input-libinput`, `xf86-input-evdev`,
  `libinput`, `libwacom` and the Python environment `libwacom` carries.
  xorgxrdp's `xorg.conf` sets `AutoAddDevices off` and declares `xrdpkeyb` and
  `xrdpmouse` as its only input devices, so none of it was ever loaded - there
  is no keyboard and no tablet on the other end of an RDP connection, only a
  protocol.
- the core bitmap fonts `font-misc-misc`, `font-cursor-misc` and `font-alias`.
  Nothing here sets a `FontPath`, so `xset q` on a live session reports the
  font path as exactly `built-ins` - the font path element compiled into
  libXfont2, which is where `fixed` and `cursor` come from. Those three
  packages were indexed by fontconfig and then ignored by it.
- `xrandr`, `xrdb` and its C preprocessor `mcpp`, `xset`, `xinput`, `xprop`,
  `xlsclients`, `iceauth`, `x11-ssh-askpass`: X utilities, in an image whose
  production session has no terminal to type them into.
- `display-manager.service` itself. `services.displayManager.enable` had been
  forced off for several commits already, but the unit is declared by the X
  server module rather than by the display-manager one, so what shipped until
  now was a greeter unit with an empty `ExecStart`.

Three forced-off options went with it, because all three were downstream of
this one: LightDM, `services.displayManager.enable`, and `gtk.iconCache.enable`
- whose default is literally `config.services.xserver.enable`. One switch
instead of four, and `tests/appliance-split.nix` asserts the outcomes so it
stays that way.

`services.xserver.displayManager.lightdm.enable` had to move rather than
disappear: LightDM asserts that the X server is on, and
`profiles/gui/openbox.nix` was asking for a greeter unconditionally. It now
follows `services.xserver.enable`, which is what it meant all along.

Ten MiB is not much next to Mesa, and this is the change that most deserved a
test rather than a build. "It evaluates" proves nothing about an X server
started by a daemon from a config file NixOS never reads.
`tests/xrdp-session.nix` therefore asks xrdp for a real session with
`xrdp-sesrun` - xrdp's own session starter, speaking the same SCP protocol to
`sesman` that the RDP listener does - and then checks, on that session's
display, that Xorg answers, that the font path is `built-ins`, that the
`us,ru` layout and the Win+Space toggle from `profiles/remote/xrdp.nix` took,
that Openbox owns the root window, and that the Spotify window is up and
maximised. The X clients in it run as `rdp` with the session's own
`Xauthority`, because `sesman` starts Xorg with `-auth` and root cannot open
that display.

### The Disk Was Sized For A Fear, Not A Measurement

`virtualisation.diskSize` said 30 GiB, with the comment `Need 30 GB o_O`. With
the closure at 1.5 GiB, the candidates measure like this - ext4 metadata from
`mkfs.ext4` on an image of each size, free space after installing the system,
and the journal cap systemd derives from the filesystem (10%, capped at 4 GiB):

| Disk | ext4 metadata | Free after the system | Journal cap |
| --- | --- | --- | --- |
| 4 GiB | 145 MiB | 2431 MiB | 410 MiB |
| 6 GiB | 186 MiB | 4438 MiB | 614 MiB |
| **8 GiB** | **231 MiB** | **6441 MiB** | **819 MiB** |
| 30 GiB | 656 MiB | 28544 MiB | 3072 MiB |

A dynamic VHDX does not allocate the virtual size up front - a freshly
formatted image is 68 MiB at 4 GiB and 135 MiB at 30 - but ext4 writes its
inode tables lazily after the first mount, so the 30 GiB filesystem does
eventually claim its 656 MiB. The other half of the argument is the journal:
at 30 GiB systemd is willing to keep 3 GiB of logs on a machine whose entire
system is 1.5 GiB. 8 GiB is four times the image with the log cap at a sane
819 MiB, so that is what it is now.

Debug images keep every bit of it, plus ssh, strace, an xterm and a mixer. The
switch is `qubix.mode`, and `machines/spotibox-debug.nix` is still three lines.

The Spotify line in that table is worth spelling out, because the obvious
reading of it is wrong. The nixpkgs package exports an `LD_LIBRARY_PATH`
naming every library Spotify might ever `dlopen`, and Nix reads each of those
store paths as a reference - but `readelf -d` says most of them are `DT_NEEDED`
of `libcef.so` or of the Spotify binary itself, CUPS and libayatana-appindicator
and libdbusmenu among them. Dropping those does not shrink the image, it stops
the process at exec time. The two that actually paid were subtler:

- Spotify links `libavcodec` and `libavformat` out of `ffmpeg_4`, and referring
  to that lib output keeps all of it - including `libavdevice`, whose SDL
  output device pulls SDL3, which pulls zenity, GTK4, gst-plugins-bad,
  PipeWire, BlueZ, `spandsp` (a fax-modem DSP library) and `libajantv2`
  (support for AJA broadcast capture cards). `ffmpeg_4-headless` is the same
  4.4.6 with the same decoders - aac, mp3, opus, vorbis, flac, pcm - and none
  of the tail.
- `zenity` is on `PATH` for the folder picker behind "add local files". A kiosk
  has no local files; traced through a startup, Spotify never runs it.

Perl deserves a note, because the obvious explanation was wrong twice. It is
not in the image because the activation scripts are written in it - or rather,
it was not *only* that. `services.graphical-desktop.enable`, which follows
`services.xserver.enable` around, installs `xdg-utils`, and xdg-utils is a pile
of Perl scripts with `libwww-perl` and `XML-Twig` behind them. Only once that
was gone did the activation scripts become the last holder, and then nixpkgs'
own `profiles/perlless.nix` had the answer: an overlayfs `/etc` instead of
`setup-etc.pl`, `userborn` instead of `update-users-groups.pl`, and
`system.forbiddenDependenciesRegexes = [ "perl" ]` to keep it out. The
production profile now carries that regex list for every ghost this branch has
exorcised, because a closure budget only says "bigger" - a package can come
back transitively while something else shrinks and the total stays inside.

What is left is mostly honest: Spotify itself (345 MiB), the kernel and its
modules (126 MiB), a python3 (107 MiB) that four separate things need
(`hyperv-daemons`, `cloud-utils` for `growPartition`, the systemd-boot
generation builder and glib's `gdbus-codegen`), systemd, and the
GTK3/Xorg/xrdp/PulseAudio path the appliance exists to run.

`environment.corePackages` is now an allowlist rather than NixOS's set of
"core packages for a normal interactive system". Two upstream modules add to
that set unconditionally and offer no way to refuse -
`nixos/modules/programs/ssh.nix` contributes an OpenSSH client to a machine
whose sshd is forced off, and `nixos/modules/tasks/network-interfaces.nix`
contributes BIND's `host` to one with static resolvers - so the list is
replaced with what something on this image can still reach through
`/run/current-system/sw/bin`. Not busybox: the scripts that survive expect GNU
semantics, and swapping the implementation to save a few megabytes is how you
get a bug report six months later about a flag that quietly means something
else.

That also answered the `nix.enable` question from earlier in this file. It is
worth 9 MiB, not the 49 the nix closure suggests, because the systemd-boot
generation builder interpolates `${config.nix.package}/bin/nix-env` and keeps
the package alive regardless. What actually leaves is the daemon, its socket,
and the OpenSSH client that was on nix-daemon's `PATH` for remote builds. The
one step this branch cannot verify is `switch-to-configuration boot` inside
make-disk-image, which needs KVM; if it minds, it will say so at image build
rather than at the user's.

`tools/closure.sh roots` ranks the system packages by *added size* - what
actually leaves the closure if that one package is dropped, which is the only
number worth acting on, since a 300 MiB package is free when everything it
needs is already there. It found the next two candidates immediately: the
appliance carries an OpenSSH client (9 MiB) with sshd disabled, and BIND's
`host` (8 MiB) with static resolvers, both because
`nixos/modules/programs/ssh.nix` and `nixos/modules/tasks/network-interfaces.nix`
add them to `environment.corePackages` unconditionally. There is no option to
switch either off; `environment.corePackages` would have to be replaced with an
allowlist, and that is a separate experiment - system scripts expect GNU
semantics, and "it still boots" is not the same as "nothing broke".

### Why The Image Is ext4, And What Compression Would Buy

The store compresses about two and a half to one, measured rather than
guessed, on the 1.65 GiB production closure:

| | Size | Ratio |
| --- | --- | --- |
| the closure itself | 1686 MiB | - |
| squashfs, zstd-6 (128 KiB blocks) | 651 MiB | 2.59x |
| `tar \| zstd -3`, roughly what btrfs `compress=zstd` achieves | 663 MiB | 2.54x |
| erofs, zstd-6 (systemd-repart's defaults, 4 KiB clusters) | ~812 MiB | 2.08x |
| `tar \| gzip -9`, roughly today's release asset | 715 MiB | - |

None of it is reachable from where this repo stands, and not for want of
trying: `nixos/lib/make-disk-image.nix`, which the `nixos-generators` Hyper-V
format calls, asserts

```text
to produce a partition table, we need to use -E offset flag which is support
only for fsType = ext4
```

so an image with a partition table - which a Generation 2 VM needs, because it
needs an ESP - is ext4 or nothing. That is a property of the builder, not a
decision anybody made here.

The door out is `image.repart`, NixOS's systemd-repart image module. It takes
any filesystem systemd-repart can format (btrfs, erofs, squashfs, xfs), and
`image.repart.verityStore` ships the appliance shape directly: a tmpfs root, a
compressed erofs `/nix/store` under dm-verity, and a UKI on the ESP. Built
against this configuration as an experiment it produces the image in tens of
seconds, in a plain Nix build with no QEMU and no KVM - which is also how the
release job could stop needing the `/dev/kvm` dance it currently performs.

That image was booted under OVMF to see whether the shape actually works, and
it does: firmware to UKI, dm-verity set up from the `usrhash=` on the kernel
command line, `/nix/store` mounted read-only off `/dev/mapper/usr`, root on
tmpfs, `multi-user.target` reached with **zero failed units** and xrdp and
xrdp-sesman both active and listening on 3389.

It also found the trap, which is why the filesystem matters more than the
algorithm. systemd-repart will cheerfully build an erofs with
`Compression=zstd`, and the stock NixOS kernel cannot mount it:

```text
erofs: (device dm-0): z_erofs_parse_cfgs: algorithm 3 isn't enabled on this kernel
[FAILED] Failed to mount /sysusr/usr.
```

`CONFIG_EROFS_FS_ZIP=y` but `CONFIG_EROFS_FS_ZIP_ZSTD is not set`, so the image
builds, passes its verity check, and then drops straight into emergency mode on
a machine nobody can log into. LZ4 is the only algorithm the stock kernel's
erofs has. Squashfs, on the other hand, is built `CONFIG_SQUASHFS_ZSTD=y` - and
its 128 KiB blocks compress better than erofs's 4 KiB clusters anyway:

| store filesystem | Image | Boots on the stock kernel |
| --- | --- | --- |
| erofs, no compression | 1868 MiB | yes |
| erofs, `Compression=zstd` | 968 MiB | **no** |
| erofs, `Compression=lz4hc` | 1144 MiB | yes |
| **squashfs, `Compression=zstd`** | **839 MiB** | **yes** |

The squashfs image breaks down as 691 MiB of store, 46 MiB of verity hashes and
the ESP. Enabling `EROFS_FS_ZIP_ZSTD` in a custom kernel would buy back erofs's
faster random reads, but not size - and it would cost a from-source kernel
build in every release, since that config is not what cache.nixos.org has.

The ESP has a floor that is not where `SizeMinBytes` says it is.
systemd-repart will not make a vfat partition smaller than 100 MiB: asking for
8M, 64M or 96M all produce exactly 100 MiB, while 300M produces 300 MiB. FAT32
wants 65525 clusters and repart refuses to go below a safe minimum. The way
around it is to stop asking repart to format the ESP at all - build the FAT
image in its own derivation, put the UKI in it with `mtools`, and hand repart
the result with `CopyBlocks=`:

| | Image |
| --- | --- |
| 100 MiB ESP (repart's vfat floor) | 839 MiB |
| 64 MiB ESP via `CopyBlocks=` | 803 MiB |
| **40 MiB ESP, after trimming the initrd** | **775 MiB** |

That variant also builds without a privileged mount, because `CopyBlocks=`
skips both `mkfs.vfat` and the loopback mount that populating a vfat partition
otherwise needs.

Below the ESP sits the UKI, and inside it the initrd, which starts at 22 MiB
compressed out of a 34 MiB UKI. Two settings take it to 19 MiB without
rebuilding anything: `boot.initrd.compressorArgs = [ "-19" "-T0" ]`, because
NixOS does not compress the initrd as hard as zstd can, and
`boot.initrd.includeDefaultModules = false` with the three storage modules this
machine actually has. The UKI drops to 31 MiB, the ESP can then be 40 MiB, and
the store shrinks a little too since the initrd lives in it. Total: 803 MiB
to 775 MiB.

The remaining 19 MiB is mostly not the initrd's own doing. Unpacked it is
39 MiB, of which systemd is 15 MiB and its dependency tail - OpenSSL 8.5 MiB,
tpm2-tss 3.2 MiB, Kerberos 1.7 MiB, curl, GMP, PCRE2 - is another 15 MiB;
kernel modules are 1.9 MiB. Dropping that tail would take the initrd to 13 MiB
compressed, but it is what `boot.initrd.systemd.package` is, and that defaults
to the full `config.systemd.package`. Two things block the obvious fixes:

- `pkgs.systemdMinimal` is built `withCryptsetup = false`, so it has no
  `systemd-veritysetup` and cannot set up the store this image boots from.
- lvm2 is not optional either. `nixos/modules/system/boot/systemd/dm-verity.nix`
  sets `boot.initrd.services.lvm.enable = true` on purpose: device-mapper's
  udev rules live in lvm2, and without them `/dev/mapper/usr` never appears.

So a smaller initrd means a systemd built from source with a custom feature
set, in every release, to save about 9 MiB in an 800 MiB image. The store is
688 of those 775 MiB; that is where the next gigabyte is, if there is one.

Two things are worth knowing before anyone reaches for it:

- **Compression does not make the download much smaller.** The release asset is
  a gzip of the image, and gzip of an already-compressed filesystem gains
  nothing: 715 MiB today against 775 MiB for the squashfs image. What does
  shrink is the space the VM occupies on the Windows host, because a dynamic
  VHDX only allocates the blocks the filesystem actually wrote: roughly 1.8 GB
  now against 775 MiB. The download is a wash; the footprint drops by 2.4x.
- Hardlink deduplication - what `nix-store --optimise` does - is not the
  missing gigabyte. Hashing every file in the closure finds 4192 duplicates
  worth 29 MiB, or 1.8%. Nix already deduplicates at the granularity that
  matters.

ZFS was considered and measured rather than argued about. Neither
make-disk-image nor systemd-repart can format it, so it would need a third
image pipeline; `pkgs.zfs`'s closure is 351 MiB, a fifth of the entire
appliance, before the out-of-tree module built per kernel; and the ARC would
claim half the VM's RAM by default. What it offers - transparent compression,
checksums, snapshots - is compression this already gets for free, integrity
that dm-verity does better for a read-only store, and snapshots of a system
disk the design already treats as disposable. The one place it could earn its
keep is the persistent `/home` disk, which mostly holds an already-compressed
Spotify cache.

Secure Boot is already off on the VM (`Set-VMFirmware -EnableSecureBoot Off`),
so an unsigned UKI would boot; the work is the rest of the pipeline - image
file name, manifest, `qubixctl`, the home disk and the release job.

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
  image/hyperv.nix         Hyper-V image without the nixpkgs channel copy
  kernel/default.nix
  modes/debug.nix, prod.nix  what a debug image adds, what a production one drops
  network/default.nix
  remote/xrdp.nix          xrdp server, session = qubix.session.command
  security/minimal.nix
  storage/persistent-home.nix
tools/
  qubixctl.ps1             controller
  qubixctl.cmd             console wrapper
  qubix-up.cmd             double-click launcher (elevates, runs `up`)
  update-manifest.sh
  closure.sh               closure census and budget (report/diff/why/check/baseline)
tests/
  spotibox-basic.nix       NixOS VM test: what the image contains
  xrdp-session.nix         NixOS VM test: a real xrdp session, X, keyboard, kiosk
  appliance-split.nix      evaluation-only guard for the prod/debug split
  closure-budget.nix       recorded production closure budget, enforced by CI
  qubixctl.Tests.ps1       controller unit checks
.github/workflows/
  ci.yml, release.yml
```

## TODO / Later Goals

- Move the image to `image.repart` with a dm-verity-protected squashfs store
  (see *Why The Image Is ext4*). It halves what the VM occupies on the host,
  makes the system disk verifiable rather than merely disposable, and drops the
  KVM requirement from the release job - at the cost of a slightly larger
  download and a new boot path (UKI + systemd initrd). The shape is proven: it
  boots, mounts the store off `/dev/mapper/usr`, and brings xrdp up with no
  failed units. What is not done is the pipeline around it.
- Spotify network lockdown via nftables, proxy or DNS allowlist.
- PipeWire + EasyEffects experiment once xrdp audio is understood.
- Hardening profile, possibly inspired by nix-mineral, applied carefully.
- Sign the closure work off against real hardware: the Mesa/LLVM and Spotify
  cuts were traced and booted in a QEMU VM (window on screen, no system GL
  opened, every decoder still present), but nothing here has logged into
  Spotify or played a track over mstsc yet. Do one cold run of each image
  before tagging a release.
- `nix.enable = false` for production images (~49 MiB). Not done yet because
  the systemd-boot generation builder calls `nix-env` by an interpolated store
  path, so the package may well stay in the closure anyway, and the bootloader
  step runs inside the image build - which needs KVM to test.
- `alsa-plugins` pulls a full ffmpeg 8 (32 MiB) into an appliance that already
  has ffmpeg 4 for Spotify; GTK3 pulls `iso-codes` (23 MiB) for a language list
  the kiosk never shows. Both need package overrides rather than options.
- Kernel profile experiments: default/latest/hardened first, custom tiny kernel
  later. 126 MiB of the image is kernel modules, for a machine with exactly one
  virtualised bus.
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
