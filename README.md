# Proxmarchy — Omarchy on Proxmox, one-liner

[![Status: Beta](https://img.shields.io/badge/status-beta-orange.svg)](#status)
[![Version](https://img.shields.io/badge/version-0.1.6--beta-blue.svg)](VERSION)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A Proxmox-host one-liner that creates a UEFI / Q35 / virtio-gpu VM and boots
the official Omarchy ISO. The end user follows the **Omarchy install
wizard** in the Proxmox console (keyboard → user → disk → confirm) to
install the OS. Once installed, the VM is fully updatable from inside
itself with `omarchy update` (which `git pull`s the official
`basecamp/omarchy` repo and refreshes the Omarchy pacman mirror).

| File | Where it runs | What it does |
|---|---|---|
| `omarchy-vm.sh` | **Proxmox host shell** (root) | Downloads the latest official Omarchy ISO from `omarchy.org` at run time, creates a UEFI / Q35 / virtio-gpu Proxmox VM, attaches the ISO, starts the VM. The user follows the Omarchy wizard in the console. |
| `omarchy-in-vm.sh` | Inside a plain Arch VM (sudoer) | Installs the missing bits and runs the official `omarchy.org/install` (which clones `github.com/basecamp/omarchy`). Useful for converting an existing plain Arch VM. |

## Status

This is a public beta line. Issues and PRs welcome.

---

## The one-liner (Proxmox host)

**Most reliable — `force-fresh.sh` clones the repo via the Git protocol** (no HTTP cache, no API, no CDN in the way):

```bash
# 1. Save the absolute-latest omarchy-vm.sh to /tmp/omarchy-vm.sh
bash <(curl -fsSL https://raw.githubusercontent.com/jj19/proxmarchy/main/force-fresh.sh)

# 2. Verify you're on the latest
grep -m 1 PROXMARCHY_VERSION /tmp/omarchy-vm.sh

# 3. Run it
bash /tmp/omarchy-vm.sh
```

`force-fresh.sh` itself uses `git clone --depth 1 --filter=blob:none
--sparse` (saves bandwidth — only the one file is fetched) so the
result is guaranteed to be the freshest content of `omarchy-vm.sh`
on `main`, no matter what any HTTP cache in your path thinks. Falls
back to the GitHub API, then the raw CDN, in order.

**API one-liner (no `gh` needed, works on a stock Proxmox host)** — when
the `force-fresh.sh` URL above is itself being cached:

```bash
curl -fsSL "https://api.github.com/repos/jj19/proxmarchy/contents/omarchy-vm.sh" \
  | python3 -c 'import json,sys,base64; sys.stdout.write(base64.b64decode(json.load(sys.stdin)["content"]).decode())' \
  > /tmp/omarchy-vm.sh
grep -m 1 PROXMARCHY_VERSION /tmp/omarchy-vm.sh
bash /tmp/omarchy-vm.sh
```

**Steady-state (when everything is cached fresh)**:

```bash
bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/jj19/proxmarchy/main/omarchy-vm.sh?nocache='$(date +%s))"
```

The first line of output should always be:

```
Proxmarchy omarchy-vm.sh v0.X.Y-beta  (commit: <short SHA>)
```

If the version doesn't match what the latest release notes say, use
the `force-fresh.sh` one-liner — it bypasses every cache.

Run from the **Proxmox node shell** (Datacenter → Node → Shell), as root,
on Proxmox VE 8.x or 9.x. The script will:

1. Ask Default / Advanced settings (VMID, hostname, cores, RAM, disk,
   bridge, MAC, start-when-done).
2. Ask which Proxmox storage pool to use for the ISO (and, if needed, a
   separate one for the VM disk — PVE 9 defaults to `local` for ISO and
   `local-lvm` for images).
3. Scrape `https://omarchy.org/` for the **current** ISO link, reuse it
   if it's already in your Proxmox storage, otherwise download + copy
   it in.
4. `qm create` the VM with the Omarchy-recommended settings:
   - UEFI (OVMF), `pre-enrolled-keys=0` (no Secure Boot — `limine` boot)
   - `q35` machine
   - `cpu host`, 4 cores, 8 GiB RAM (defaults; configurable in Advanced)
   - `vga virtio` (the best Wayland / Hyprland path on Proxmox)
   - `scsihw virtio-scsi-single`, virtio NIC
   - `serial0 socket` for Proxmox xterm.js console
   - 100 GiB virtio-scsi disk (default)
5. Attach the Omarchy ISO on `ide2`.
6. Set `boot order=scsi0;ide2` — empty disk falls through to the ISO on
   first boot, then boots from disk after install.
7. Start the VM.
8. Print next-step instructions. (No ISO upload / cidata / unattended
   stuff to clean up afterwards.)

### Defaults you can change

| Setting | Default | Notes |
|---|---|---|
| VMID | next free | |
| Hostname | `omarchy` | |
| Cores | 4 | Hyprland wants at least 2 |
| RAM | 8192 MiB | minimum 4096 enforced |
| Disk | 100 GiB | minimum 64 enforced |
| Bridge | `vmbr0` | |
| Install mode | **Omarchy wizard** (in the Proxmox console) | no unattended/cidata option — keep it simple |
| Start when done | yes | |
| **Remove Omarchy ISO after install** | **yes** | toggleable in Advanced; the ISO is 6 GB, so this saves real space. The VM doesn't need it after install (boot order is `scsi0;ide2`, disk wins). |
| **End user on macOS?** | **no** | toggleable in Advanced; if "yes", the script pre-stages a small data CD-ROM (volume label `FIX`, attached to `ide3`) with the [`fix-mac-super-key.sh`](#console-options--what-to-use-when) script on it. The post-install "Next steps" output tells the end user to type `bash /run/media/<user>/FIX/fix.sh` (34 chars) to apply the fix — no clipboard needed (noVNC has no paste). The data CD-ROM is detached and removed in the post-install cleanup. |

### Cleanup behavior

- **Always**: the script's own `TEMP_DIR` (the originally downloaded
  file) is wiped on exit via a `trap cleanup EXIT`.
- **Default yes, toggleable in Advanced**: the 6 GB Omarchy ISO is also
  detached and removed from Proxmox storage. Say "No" only if you want
  to keep it to re-install or build another Omarchy VM later.

If you keep the ISO, you'll find it at `<storage path>/template/iso/`
(usually `/var/lib/vz/template/iso/omarchy-X.Y.Z.iso`) and can detach it
manually later with `qm set <vmid> -delete ide2`.

---

## What the end user does after the one-liner

Two flows, pick one:

**Standard flow** (uses the upstream Omarchy ISO + the data CD-ROM
for the mac-fix; requires the user to run `--complete` once after
the wizard finishes):

The script ends with:

```
  💡  Next steps
  • Open the Proxmox console for VM <id> (noVNC or xterm.js).
  • The VM boots from the Omarchy ISO — walk through the wizard in the
    console: keyboard → user → disk → confirm. Installation finishes in
    a few minutes; on the next reboot the VM boots from disk into the
    Hyprland desktop.
```

The user follows the wizard, picks a username/password/hostname/timezone,
confirms the disk, and on the next reboot lands on the Hyprland
desktop. They can then keep the VM current with:

- `omarchy update` (terminal)
- **Super + Alt + Space → Update → Omarchy** (menu)

### Console options — what to use when

Proxmox gives you three ways to reach the VM console. They have different
tradeoffs depending on your platform:

| Console | Best for | Gotchas |
|---|---|---|
| **noVNC** (browser) | Everything on the install wizard, occasional GUI access | The **Super / Cmd / Win key is often eaten by the browser or the OS** before it reaches the VM. `Super + Space` and `Super + Enter` may not fire. Workaround: remap Super → Right Alt or Caps Lock in `~/.config/hypr/hyprland.conf`. |
| **xterm.js** (browser, serial) | Text-mode work, debugging, when the framebuffer hangs. Connects to the VM's `serial0` socket. | Boot messages and the Omarchy install wizard render on the framebuffer, **not** serial, by default — so the install wizard shows nothing on this console unless the kernel is told to use serial too (`-args "-console=ttyS0,115200"` in the VM config). Useful for post-install TTYs once configured. |
| **SPICE** (native client) | Best keyboard passthrough — Super, Alt+Tab, media keys all work. | The official macOS Remote Viewer is the ancient 0.5.7 build and **doesn't understand Proxmox's modern `pvespiceproxy:...` ticket format**. Modern virt-viewer 11.0+ has no maintained macOS binary. On Linux it's a one-liner (`apt install virt-viewer`); on Windows it's the official MSI. |

### Recommended workflow

- **Linux / Windows desktop user**: install `virt-viewer` and use SPICE
  for everything. Best keyboard, no fuss.
- **macOS user — pure GUI via noVNC**: open the Proxmox noVNC console
  for the VM. **The Proxmox installer (v0.1.11+) automatically pre-stages
  a small data CD-ROM with the fix script on it**, because noVNC has
  no clipboard and you can't paste a one-liner. Just open a terminal
  inside the Hyprland desktop (right-click the desktop) and type:
  ```bash
  bash /run/media/omarchy/FIX/fix.sh
  ```
  (If your username isn't `omarchy`, run `ls /run/media/` to find the
  right path. Adjust the path accordingly.) After it runs, `Alt + Space`
  opens the Omarchy menu, `Alt + Enter` opens a terminal, and every
  other Super+X keybind in Omarchy also remaps to Alt+X. Re-run with
  `bash /run/media/omarchy/FIX/fix.sh -- --undo` to revert.

  If you're using this script standalone (not the Proxmox installer),
  or if the data CD-ROM is gone, the equivalent long one-liner is:
  ```bash
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/jj19/proxmarchy/main/fix-mac-super-key.sh)"
  ```

  What it does:
  1. Backs up `~/.config/hypr/hyprland.conf` to
     `~/.config/hypr/backup-super-fix/hyprland.conf.bak.<timestamp>`.
  2. Adds `kb_options = altwin:swap_alt_win` to the `input { ... }`
     block (or appends a new one). This swaps Alt and Super at the
     XKB level inside Hyprland, so Omarchy's `bind = SUPER, X, ...`
     keybinds now fire on the physical Alt key — which noVNC
     passes through cleanly.
  3. Runs `hyprctl reload` so the change takes effect immediately
     (no log out required).

  To revert: re-run the same command with `--undo`.

  Optional — make your physical Mac Cmd key act as Alt in the VM
  too, so your muscle memory works: install
  [Karabiner-Elements](https://karabiner-elements.pqrs.org/) on
  the Mac and add a "Simple Modification": `left_command` →
  `left_alt`. After that, pressing Cmd on your Mac is equivalent
  to pressing Alt in the VM, and Omarchy's Super keybinds fire.

- **macOS user — SSH-based workflow** (if you don't want to fight
  the keyboard at all): use noVNC for the install wizard, then
  ```bash
  ssh omarchy@<vm-ip>
  ```
  Find the VM's IP from the Proxmox UI (VM → Summary) or run
  `ip -4 addr show` from the noVNC console once the VM is on the
  network. SSH gives you a real terminal, full keyboard, copy/paste.

---

## The other one-liner (in-VM, plain Arch → Omarchy)

If you already have an Arch VM (e.g. from
`community-scripts/ProxmoxVE/vm/archlinux-vm.sh`) and want to convert it
**in place** without rebuilding the VM:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jj19/proxmarchy/main/omarchy-in-vm.sh)"
```

This:

1. Installs `git`, `gum`, `base-devel` (Omarchy's installer needs them).
2. Runs the **official** upstream installer: `omarchy.org/install`, which
   is the project's own `boot.sh` — it clones `github.com/basecamp/omarchy`
   into `~/.local/share/omarchy` and runs the full `install.sh` from
   there.
3. After the first reboot, `omarchy update` is the maintenance command.

To pin to a different release channel:

```bash
OMARCHY_REF=dev bash -c "$(curl -fsSL https://omarchy.org/install)"
```

(`master` / `stable` / `rc` / `dev` are the four channels.)

---

## Why the resulting VM stays up to date

Omarchy is not a frozen image. The official `install.sh` (which the ISO
wizard runs from `github.com/basecamp/omarchy`) sets up four update
channels through `~/.local/share/omarchy`:

- `~/.local/share/omarchy` — a git clone of the Omarchy repo. `omarchy
  update` runs `git -C ~/.local/share/omarchy pull --autostash` to
  pull the latest scripts, themes, defaults, migrations, and
  `omarchy-*` CLI commands.
- `/etc/pacman.d/mirrorlist` — points at the Omarchy Arch mirror
  (`https://stable-mirror.omarchy.org/$repo/os/$arch`). `omarchy-update
  system-pkgs` runs `pacman -Syu` against it, so Omarchy-specific
  packages track upstream releases.
- The Omarchy package repo registered with `pacman` — Omarchy itself
  is shipped as regular pacman packages, so a `pacman -Syu` picks up
  new Omarchy releases.
- `~/.local/share/omarchy/migrations/` — `omarchy update` runs any
  pending migration scripts to keep your config in sync with the
  latest release.

So the same `omarchy update` (or the **Update → Omarchy** entry in the
Omarchy menu) does **both** "refresh the Omarchy scripts from the
official repo" and "pull the latest Omarchy and Arch packages" — that's
how the in-VM experience stays current without rebuilding the VM.

---

## Why "stay up to date when installing" matters here

The Proxmox-side script **always** scrapes `https://omarchy.org/` for
the ISO link at run time, so you get whatever the team just released.
The in-VM `omarchy.org/install` URL points at the same `boot.sh` on
the `master` branch, which clones the same `basecamp/omarchy` repo
your future `omarchy update` will pull from. There is no pinned,
stale mirror anywhere in the chain.

---

## Files

```
omarchy/
├── omarchy-vm.sh                # Proxmox-host one-liner (this is the main one)
├── omarchy-in-vm.sh             # in-VM one-liner (Arch → Omarchy)
├── fix-mac-super-key.sh         # in-VM one-liner: remap Super → Alt for noVNC on macOS
├── force-fresh.sh               # Proxmox-host: bypasses all HTTP caches via git clone
├── build-custom-iso.sh          # Proxmox-host: build a Proxmarchy-customized Omarchy ISO
├── iso-customizations/          # Files injected by build-custom-iso.sh
│   ├── etc/systemd/system/proxmarchy-install-detect.service
│   └── usr/local/bin/proxmarchy-install-detect.sh
├── README.md                    # this file
├── LICENSE                      # MIT
├── CHANGELOG.md                 # per-version notes
└── VERSION                      # current version
```

---

## Building a Proxmarchy-customized ISO (advanced)

The standard flow asks the end user to run `omarchy-vm.sh --complete`
once after the Omarchy wizard finishes. For a fully-automated
"walk through the wizard, log in to Hyprland, done" experience,
build a custom ISO that auto-applies the mac-fix on first boot
of the installed system.

**How it works**

1. `build-custom-iso.sh` downloads the latest Omarchy ISO
2. It extracts the archiso squashfs and injects two things:
   - `proxmarchy-install-detect.service` (live-env systemd service)
   - `proxmarchy-install-detect.sh` (watches /mnt for install completion)
3. It repacks the squashfs and produces
   `proxmarchy-omarchy-<version>.iso`
4. When the user boots the custom ISO, the live-env service
   watches `/mnt` for the install wizard to finish
5. When the install target is stable (hostname unchanged for
   10 s), the service writes a `proxmarchy-first-boot.service`
   into `/mnt/etc/systemd/system/` and `arch-chroot systemctl
   enable`s it
6. The system reboots into the installed Omarchy; the
   first-boot service runs once, applies the mac-fix, and
   writes a marker file (idempotent on every subsequent boot)

**To build**

```bash
# On any Linux host (Debian / Ubuntu / Proxmox — needs xorriso,
# squashfs-tools, curl, sudo):
sudo apt install xorriso squashfs-tools
./build-custom-iso.sh
# Default output: ./proxmarchy-omarchy-<version>.iso
```

**To use**

1. Upload the custom ISO to Proxmox:
   ```bash
   scp proxmarchy-omarchy-4.0.1.iso root@mjproxmox:/var/lib/vz/template/iso/
   ```
2. Run `omarchy-vm.sh` and set `ISO_FILE` to
   `proxmarchy-omarchy-4.0.1.iso` when prompted (or hard-code
   it in the script for now)
3. Walk through the wizard. When it finishes, run
   `--complete` as usual. The fix is applied automatically
   on first boot of the installed system.

**Caveats**

- The custom ISO is **out of date** the moment a new Omarchy
  ships. Rebuild it whenever the upstream ISO bumps. The
  build script always pulls the latest.
- The custom ISO **bakes in the version of `fix-mac-super-key.sh`
  that was current when the ISO was built**. Newer fixes won't
  reach the user until they re-run the curl one-liner or
  rebuild the ISO. For most cases this is fine — the fix
  script is stable.
- This is **beta**. Test on a throwaway VM first.

---

## Tested reference settings (manual)

For users who prefer to do it by hand, the Proxmox recipe is:

```bash
qm create 101 --name my-omarchy \
  --bios ovmf --machine q35 --cpu host --cores 4 --memory 8192 \
  --ostype l26 --scsihw virtio-scsi-single \
  --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0 \
  --scsi0 local-lvm:100,discard=on,iothread=1 \
  --net0 virtio,bridge=vmbr0 \
  --vga none \
  --serial0 socket \
  --balloon 0 \
  --args '-display none -device virtio-gpu,blob=true,venus=true,max_outputs=1 -device ich9-intel-hda,id=sound0,bus=pci.0,addr=0x18 -device intel-hda-duplex,id=sound0-codec0,bus=sound0.0,cad=0' \
  --ide2 local:iso/omarchy.iso,media=cdrom \
  --boot order='scsi0;ide2'
qm start 101
```

(The script automates exactly this, plus the ISO download and the
`omarchy.org`-driven update story.)

### Performance + sound rationale

The defaults the script picks are tuned for a snappy Hyprland
desktop — not for "minimum viable VM":

- **Raw QEMU args for display + GPU** (PVE 8.1+): the modern
  split is `-display none` (kill the legacy VGA emulated
  display) + a dedicated `virtio-gpu` with `blob=true` and
  `venus=true` for host-side 3D acceleration. This is what
  unblocks smooth Hyprland / Wayland rendering — the legacy
  `--vga virtio` (the `-memory 64` variant in particular) is
  2D-only and software-renders most things, so animations and
  shadows lag.
  - We pass these via `qm set ... -args` rather than the newer
    `qm set --display` / `qm set --gpu` flags because the
    latter are missing from some Proxmox API schemas /
    `pve-qemu-kvm` package versions, and the API rejects them
    with `Unknown option: display` + `400 unable to parse
    option`. Raw `-args` works on every Proxmox version and is
    what the Proxmox web UI does under the hood for the same
    settings.
- **`-balloon 0`**: disable the memory ballooning device. The
  default balloon causes memory pressure and latency spikes as
  Proxmox reclaims RAM. With the VM sized for its workload
  (default 8 GiB), pinning the allocation is strictly better.
- **`ich9-intel-hda` + `intel-hda-duplex`**: Intel HDA on the
  ICH9 bus. PipeWire / WirePlumber in Omarchy auto-detect it as
  an ALSA sink/source. The user will see it in `pactl list sinks
  short` and can use any PipeWire-aware app. **Note**: audio is
  not carried over noVNC (browser VNC has no audio channel), so
  it's only audible over a SPICE console (Linux `virt-viewer` /
  Windows). For Mac users on noVNC, the device is configured but
  inaudible in the browser — pipe it over SSH/PulseAudio's
  network sink if you actually need to hear it from macOS.
- **`-cpu host`**: pass through all host CPU features. Needed
  for `+aes`, `+avx`, `+invtsc`, etc. that Hyprland and modern
  Firefox both want.
- **`virtio-scsi-single` + `iothread=1` + `discard=on` + `ssd=1`**:
  the right combo for fast virtio disk I/O on the OS disk.
- **`virtio-gpu,max_outputs=1`** (no `blob`/`venus`): the script
  uses a **2D-only virtio-gpu** so the default works on every
  Proxmox host regardless of QEMU version or host kernel
  modules. Hyprland runs and is fully usable, but it
  software-renders (llvmpipe) for any 3D work (animations,
  blur, etc.). To opt into 3D acceleration, see the next
  subsection.

### How to enable 3D acceleration (optional)

The script's default virtio-gpu is 2D-only for maximum
compatibility. If your Proxmox host is on a recent enough
QEMU and you want GPU-accelerated Hyprland, opt in manually:

1. **Load the `udmabuf` kernel module on the Proxmox host**
   (one-time, persists across reboots if you add it to
   `/etc/modules`):
   ```bash
   modprobe udmabuf
   echo udmabuf >> /etc/modules
   ```
2. **Stop the VM, add `blob=true` to the virtio-gpu args, restart**:
   ```bash
   qm stop <vmid>
   qm set <vmid> -args '-display none -device virtio-gpu,blob=true,max_outputs=1 -device ich9-intel-hda,id=sound0,bus=pci.0,addr=0x18 -device intel-hda-duplex,id=sound0-codec0,bus=sound0.0,cad=0'
   qm start <vmid>
   ```
3. **For true Vulkan passthrough** (additionally requires QEMU
   ≥ 9.0 on the host), add `,venus=true` after `blob=true`:
   ```
   -device virtio-gpu,blob=true,venus=true,max_outputs=1
   ```

After re-adding `blob=true`, Hyprland should pick up the GPU
acceleration automatically and the laggy software rendering
goes away.
