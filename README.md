# Proxmarchy — Omarchy on Proxmox, one-liner

[![Status: Beta](https://img.shields.io/badge/status-beta-orange.svg)](#status)
[![Version](https://img.shields.io/badge/version-0.1.0--beta-blue.svg)](VERSION)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Two scripts, both end up with a full **Omarchy** VM that updates itself with
`omarchy update` (which `git pull`s the official `basecamp/omarchy` repo +
refreshes the Omarchy pacman mirror).

| File | Where it runs | What it does |
|---|---|---|
| `omarchy-vm.sh` | **Proxmox host shell** (root) | Downloads the latest official Omarchy ISO from `omarchy.org` at run time, builds a `cidata` (cloud-init NoCloud) drive for unattended install, and creates a UEFI / Q35 / virtio-gpu Proxmox VM. |
| `omarchy-in-vm.sh` | Inside a plain Arch VM (sudoer) | Installs the missing bits and runs the official `omarchy.org/install` (which clones `github.com/basecamp/omarchy`). |

## Status

This is the **first public beta** (`v0.1.0-beta`). The script has been
syntax-checked and the storage.cfg parser is unit-tested against a
realistic Proxmox config, but it has not been run end-to-end on a live
Proxmox node from this exact repo yet. Issues and PRs welcome.

---

## The one-liner (Proxmox host)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/jj19/proxmarchy/main/omarchy-vm.sh)"
```

…or with `wget`:

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/jj19/proxmarchy/main/omarchy-vm.sh)"
```

Run from the **Proxmox node shell** (Datacenter → Node → Shell), as root,
on Proxmox VE 8.x or 9.0–9.2. The script will:

1. Ask Default / Advanced settings (VMID, hostname, cores, RAM, disk,
   bridge, MAC, install mode, start-when-done).
2. Ask which Proxmox storage pool to use for the ISO and the disk.
3. Scrape `https://omarchy.org/` for the **current** ISO link and download
   it into that storage pool.
4. If unattended, prompt for a Linux user / password / hostname / timezone /
   keyboard / optional SSH key, and build a `cidata` ISO.
5. `qm create` the VM with the Omarchy-recommended settings:
   - UEFI (OVMF), `pre-enrolled-keys=0` (no Secure Boot — `limine` boot)
   - `q35` machine
   - `cpu host`, 4 cores, 8 GiB RAM (defaults; configurable in Advanced)
   - `vga virtio` (the best Wayland / Hyprland path on Proxmox)
   - `scsihw virtio-scsi-single`, virtio NIC
   - `serial0 socket` for Proxmox xterm.js console
   - 100 GiB virtio-scsi disk (default)
6. Attach the Omarchy ISO (`ide2`) and the `cidata` ISO (`ide3`).
7. Set `boot order=scsi0;ide2` — empty disk falls through to the ISO on
   first boot, then boots from disk after install.
8. Optionally start the VM.

### Defaults you can change

| Setting | Default | Notes |
|---|---|---|
| VMID | next free | |
| Hostname | `omarchy` | |
| Cores | 4 | Hyprland wants at least 2 |
| RAM | 8192 MiB | minimum 4096 enforced |
| Disk | 100 GiB | minimum 64 enforced |
| Bridge | `vmbr0` | |
| Install mode | unattended (cidata) | toggleable in Advanced |
| Start when done | yes | |
| **Remove Omarchy ISO after install** | **yes** | toggleable in Advanced; the ISO is 6 GB, so this saves real space. The VM doesn't need it after install (boot order is `scsi0;ide2`, disk wins). |

### Cleanup behavior

The script does cleanup that goes a step further than `community-scripts/ProxmoxVE`
(those typically leave the imported disk image in storage for the user to
remove manually):

- **Always**: the `cidata` ISO is detached from the VM and removed from
  Proxmox storage after install — it was a one-shot consumed on the first
  boot.
- **Always**: the script's own `TEMP_DIR` (the originally downloaded files)
  is wiped on exit via a `trap cleanup EXIT`.
- **Default yes, toggleable in Advanced**: the 6 GB Omarchy ISO is also
  detached and removed from Proxmox storage. Say "No" only if you want to
  keep it to re-install or build another Omarchy VM later.

If you keep the ISO, you'll find it at `<storage path>/template/iso/`
(usually `/var/lib/vz/template/iso/omarchy-X.Y.Z.iso`) and can detach it
manually later with `qm set <vmid> -delete ide2`.

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
2. Runs the **official** upstream installer: `omarchy.org/install`, which is
   the project's own `boot.sh` — it clones `github.com/basecamp/omarchy`
   into `~/.local/share/omarchy` and runs the full `install.sh` from there.
3. After the first reboot, `omarchy update` is the maintenance command.

To pin to a different release channel:

```bash
OMARCHY_REF=dev bash -c "$(curl -fsSL https://omarchy.org/install)"
```

(`master` / `stable` / `rc` / `dev` are the four channels.)

---

## Why the resulting VM stays up to date

Omarchy is not a frozen image. The official `install.sh` (which the script
pulls from `github.com/basecamp/omarchy`) sets up four update channels
through `~/.local/share/omarchy`:

- `~/.local/share/omarchy` — a git clone of the Omarchy repo. `omarchy
  update` runs `git -C ~/.local/share/omarchy pull --autostash` to pull
  the latest scripts, themes, defaults, migrations, and `omarchy-*` CLI
  commands.
- `/etc/pacman.d/mirrorlist` — points at the Omarchy Arch mirror
  (`https://stable-mirror.omarchy.org/$repo/os/$arch`). `omarchy-update
  system-pkgs` runs `pacman -Syu` against it, so Omarchy-specific
  packages track upstream releases.
- The Omarchy package repo registered with `pacman` — Omarchy itself is
  shipped as regular pacman packages, so a `pacman -Syu` picks up new
  Omarchy releases.
- `~/.local/share/omarchy/migrations/` — `omarchy update` runs any
  pending migration scripts to keep your config in sync with the latest
  release.

So the same `omarchy update` (or the **Update → Omarchy** entry in the
Omarchy menu) does **both** "refresh the Omarchy scripts from the official
repo" and "pull the latest Omarchy and Arch packages" — that's how the
in-VM experience stays current without rebuilding the VM.

---

## Why "stay up to date when installing" matters here

The Proxmox-side script **always** scrapes `https://omarchy.org/` for the
ISO link at run time, so you get whatever the team just released. The
in-VM `omarchy.org/install` URL points at the same `boot.sh` on the
`master` branch, which clones the same `basecamp/omarchy` repo your
future `omarchy update` will pull from. There is no pinned, stale
mirror anywhere in the chain.

---

## Files

```
omarchy/
├── omarchy-vm.sh        # Proxmox-host one-liner (this is the main one)
├── omarchy-in-vm.sh     # in-VM one-liner (Arch → Omarchy)
└── README.md            # this file
```

---

## Tested reference settings (manual)

For users who prefer to do it by hand, the official Proxmox recipe is:

```bash
qm create 101 --name my-omarchy \
  --bios ovmf --machine q35 --cpu host --cores 4 --memory 8192 \
  --ostype l26 --scsihw virtio-scsi-single \
  --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0 \
  --scsi0 local-lvm:40,discard=on,iothread=1 \
  --net0 virtio,bridge=vmbr0 --vga virtio --serial0 socket \
  --ide2 local:iso/omarchy.iso,media=cdrom \
  --ide3 local:iso/cidata.iso,media=cdrom \
  --boot order='scsi0;ide2'
qm start 101
```

(The script automates exactly this, plus the ISO download, cidata build,
and the `omarchy.org`-driven update story.)
