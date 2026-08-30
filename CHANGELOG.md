# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.42-beta] — 2026-08-29

### Fixed
- **`build-custom-iso.sh` failed with "No efiboot.img found in
  the source ISO".** The Omarchy ISO (4.x) doesn't use the
  older archiso FAT-image-at-`EFI/archiso/efiboot.img` pattern;
  it puts a raw EFI binary at `EFI/BOOT/BOOTX64.EFI` (and/or
  `EFI/BOOT/BOOTIA32.EFI`) directly, and the modern xorriso
  `-e` flag accepts both forms. The build script now searches
  a broader list of canonical paths including `EFI/BOOT/BOOTX64.EFI`,
  `EFI/BOOT/BOOTIA32.EFI`, `boot/grub/efiboot.img`, and
  `boot/grub/x86_64-efi/core.efi`, with a final `find` fallback
  for any `*.efi` / `efiboot.img` / `BOOTX64.EFI` anywhere in
  the tree.

## [0.1.41-beta] — 2026-08-29

### Fixed
- **Custom ISO produced by `build-custom-iso.sh` wasn't
  bootable.** The xorriso invocation was missing the modern
  archiso flags that embed the EFI boot image as an MBR
  partition:
  - `-append_partition 2 0xef <efiboot.img>` — embeds the EFI
    image as a partition in the MBR for hybrid boot
  - `-partition_offset 16` — alignment
  - `-iso_mbr_part_type 0xef` — sets the MBR partition type
    to EFI System Partition
  Without these, some UEFI firmwares don't find the boot
  image and the VM sits at "no bootable device". The build
  also now searches canonical archiso paths first
  (`EFI/archiso/efiboot.img`, `EFI/boot/efiboot.img`,
  `boot/grub/efiboot.img`) and falls back to a broader `find`
  if none match. A post-build verification step runs
  `xorriso -report_el_torito` on the output to confirm the
  boot entry is present, with a clear warning + diagnostic
  hint if it's not.

## [0.1.40-beta] — 2026-08-29

### Added
- **`omarchy-vm.sh` auto-detects Proxmarchy-customized ISOs.**
  Before scraping `omarchy.org` for the latest ISO, the script
  now looks in the chosen Proxmox storage for any file matching
  `proxmarchy-omarchy-*.iso` (the output of
  `build-custom-iso.sh`). If found, it uses that — bypassing the
  upstream download. The glob picks up any version (rebuilt
  against a newer Omarchy, etc.) without code changes. The
  custom ISO path is preferred over the upstream one when both
  are present. To use the upstream ISO instead, just remove
  any `proxmarchy-omarchy-*.iso` from the storage.

## [0.1.39-beta] — 2026-08-29

### Fixed
- **`build-custom-iso.sh` failed at the xorriso step with
  `File "/arch/x86_64/airootfs.sfs" cannot be added to image
  because its size is 4 GiB or larger`.** The repacked
  airootfs.sfs is 5.6 GB and the default ISO 9660 level (2 or
  3) caps per-file at 4 GiB. The original Omarchy ISO uses
  ISO 9660 level 4 to lift that cap to ~4 TiB; the build
  script now matches by passing `-iso-level 4` to `xorriso
  -as mkisofs`. UEFI firmware supports level 4 universally,
  and the Omarchy ISO is UEFI-only anyway, so no compat risk.

## [0.1.38-beta] — 2026-08-29

### Fixed
- **`build-custom-iso.sh` failed at the xorriso step with
  `isohdpfx.bin does not exist` and `isolinux.bin does not
  exist`.** The Omarchy ISO (and most modern archiso ISOs) is
  UEFI-only and has no `isolinux/` directory at all; the
  script was unconditionally passing BIOS/isolinux boot flags
  that referenced non-existent files. The repackage step now
  **auto-detects** what's in the source ISO:
  - If `isolinux/isolinux.bin` and `isolinux/isohdpfx.bin`
    are both present: hybrid (BIOS+UEFI) layout (older
    archiso ISOs).
  - Otherwise: UEFI-only layout using whatever `efiboot.img`
    is found anywhere in the tree.
  - GPT basdat flag is only added when there's a UEFI image.
  The `xorriso -as mkisofs` invocation is now built from a
  `xorriso_args` array so the right flags are always passed.

## [0.1.37-beta] — 2026-08-29

### Fixed
- **`build-custom-iso.sh` failed with "No space left on device"
  during `unsquashfs` on Proxmox hosts.** Default work dir
  was `/tmp/proxmarchy-iso-build`, but `/tmp` on Proxmox is
  often a tmpfs sized to half the RAM (~8-16 GB) and the
  airootfs extracts to ~12 GB before the build can repack
  it. Defaulted the work dir to `/var/tmp/proxmarchy-iso-build`
  (on the root filesystem, typically 50+ GB on Proxmox hosts)
  and added a disk-space check in `stage_workdir` that bails
  early with a clear message and an `PROXMARCHY_BUILD_DIR=...`
  override hint if there's less than 15 GB free.

## [0.1.36-beta] — 2026-08-29

### Fixed
- **`build-custom-iso.sh` preflight required `sudo` even when
  the user was already root** (the common case on a Proxmox
  host). The check was unconditional and died with "Missing
  tool: sudo" before getting to the rest of preflight. Now:
  detect whether we're running as root, set a `SUDO` variable
  to either `""` (root) or `"sudo"` (non-root), and use
  `${SUDO}` everywhere `sudo` was previously hard-coded. The
  preflight also dropped the "Don't run as root" guard since
  running as root is now first-class.

## [0.1.35-beta] — 2026-08-29

### Added
- **`build-custom-iso.sh`** — builds a Proxmarchy-customized Omarchy
  ISO. Downloads the latest upstream Omarchy ISO, extracts the
  archiso squashfs, injects a `proxmarchy-install-detect` systemd
  service + `fix-mac-super-key.sh` + an installer-side detection
  script, repacks the squashfs, and produces a new hybrid ISO at
  `proxmarchy-omarchy-<version>.iso`. Run on a Linux host with
  `xorriso`, `squashfs-tools`, `curl`, and `sudo` (Debian /
  Proxmox / Ubuntu all have these in apt).

- **`iso-customizations/`** — the files the build script injects
  into the upstream ISO:
  - `etc/systemd/system/proxmarchy-install-detect.service` —
    live-env service that watches `/mnt` for the install wizard
    to complete
  - `usr/local/bin/proxmarchy-install-detect.sh` — its body.
    When the install target is stable (hostname unchanged for
    10 s), it injects `proxmarchy-first-boot.service` into
    `/mnt/etc/systemd/system/`, copies the fix script to
    `/mnt/opt/proxmarchy/`, and `arch-chroot systemctl enable`s
    the new service. Idempotent across live-env reboots via a
    marker file.

- **The injected first-boot service** is generated by the detect
  script (not baked into the ISO), so it works regardless of
  which install path the user takes. When the installed Omarchy
  first boots, the service runs `fix-mac-super-key.sh` once
  (the v0.1.30-beta stub-config logic handles the case where
  `~/.config/hypr/hyprland.conf` doesn't exist yet) and writes
  `/var/lib/proxmarchy-install-complete` for idempotency.

### Architecture (why the live env injects, not the ISO)

The Omarchy install is interactive and we don't control the install
scripts. We can't bake "run this on first boot of the installed
system" into the ISO directly — anything we put in the live env
runs in the live env, not the installed one. The fix: the live
env's detect service watches for the install to complete (stable
hostname at /mnt/etc/hostname), then **writes a service into the
installed system** via `arch-chroot` + `systemctl enable`. When
the system reboots into the installed Omarchy, the service is
already in place and runs on first boot.

[0.1.35-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.35-beta

## [0.1.34-beta] — 2026-08-29

### Removed
- **cidata drive (cloud-init auto-fix).** The Omarchy ISO is a
  live environment that ships with cloud-init (for cloud use
  cases), so the moment the live session boots, cloud-init sees
  our cidata drive (volume label "cidata"), processes the
  user-data, runs the fix in the live environment, and writes
  the marker file to the *live* filesystem. By the time the
  user finished the wizard and rebooted into the installed
  system, cloud-init had already consumed the cidata and the
  auto-fix never ran on the system that actually needed it.
  cidata is fundamentally broken for live-ISO installs. The
  `build_cidata_iso` function is kept dormant (not called) for
  cleanup of stale VMs from v0.1.32/v0.1.33; `--complete` will
  still detach ide1 and remove proxmarchy-cidata.iso from
  Proxmox storage if they exist.

  The "auto-fix on first boot of the installed system" requires
  either a custom Omarchy ISO with a systemd first-boot service
  or modifying the Omarchy install itself — both v0.2.0+ work.

### Changed
- **next-steps mac-fix section no longer mentions cloud-init
  auto-fix.** Replaced with the two reliable paths: the
  pre-staged data CD-ROM (auto-mounted at
  `/run/media/<user>/FIX/fix.sh`) and the GitHub curl one-liner.
  Also added a `find /run/media -name fix.sh` one-liner that
  works regardless of which username the user chose during the
  wizard.

[0.1.34-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.34-beta

## [0.1.33-beta] — 2026-08-29

### Fixed
- **\`--complete\` next-steps assumed the script was on the Proxmox
  host.** The green banner in v0.1.32-beta showed \`bash
  omarchy-vm.sh --complete <vmid>\`, but the script lives on
  the Mac (in iCloud Drive), not on the Proxmox host. Users got
  \`bash: omarchy-vm.sh: No such file or directory\`. Replaced
  with the always-works curl one-liner:

      bash -c "$(curl -fsSL https://raw.githubusercontent.com/jj19/proxmarchy/main/omarchy-vm.sh)" -- --complete <vmid>

  The \`--\` is the bash convention to forward everything after
  it as positional args to the script, so \`--complete <vmid>\`
  reaches the script and isn't interpreted by bash. Kept the
  short form (\`bash omarchy-vm.sh --complete <vmid>\`) as a
  secondary mention for users who have saved the script on the
  host.

[0.1.33-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.33-beta

## [0.1.32-beta] — 2026-08-29

### Added
- **cidata drive (cloud-init NoCloud datasource) attached as ide1
  for Mac users.** The user-data cloud-config installs
  qemu-guest-agent, enables it, applies the mac-fix on first
  boot, and writes a marker file. If the Omarchy image includes
  cloud-init (most archinstall-based installs do), the mac-fix
  is applied automatically — no user action needed beyond
  `--complete` and logging into SDDM. If cloud-init isn't
  installed, the cidata drive is just an unread CD-ROM and the
  user falls back to the GitHub one-liner (printed in
  next-steps and the `--complete` output).
- **`--complete <vmid>` subcommand.** Replaces the v0.1.28-beta
  manual "stop the install loop" one-liner. Does ALL host-side
  cleanup in one invocation: stops the VM, detaches ide1 + ide2
  + ide3, switches boot order to disk-only, removes the source
  ISOs from Proxmox storage (~6 GB freed), and starts the VM.
  Idempotent — safe to run multiple times. Prints the fallback
  one-liner for the mac-fix (in case cloud-init didn't take).
- **`--destroy <vmid>` subcommand** for quick VM teardown.
- **`--help` subcommand** with the full usage block.
- **Replaced the v0.1.28-beta "STOP THE INSTALL LOOP" red banner**
  with a green "AFTER THE WIZARD: one command does all the
  host-side cleanup" banner that points at `--complete`. The
  install-loop problem is now solved by the subcommand, not by
  a one-liner the user has to remember.

### Changed
- **The post-install workflow is now: wizard → `--complete` →
  log in.** Down from 4-5 manual steps (loop-breaker, ISO
  detach, ide3 detach, fix script, login). Mac users with
  cloud-init in the image: 2 actions after the wizard
  (`--complete`, login). Mac users without cloud-init: 3
  actions (`--complete`, login, curl fallback). Non-Mac users:
  2 actions (`--complete`, login).

[0.1.32-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.32-beta

## [0.1.31-beta] — 2026-08-29

### Added
- **Warning in next-steps: "Don't start Hyprland from a TTY."**
  Hyprland will start from a TTY but XWayland (which it spawns
  for X11 apps) will fail with `KMS: DRM_IOCTL_MODE_CREATE_DUMB
  failed: Permission denied` because TTYs don't have a
  logind-managed seat. The user is then stuck with a
  half-working Hyprland session and no X11 support. The fix is
  to use SDDM (the display manager Omarchy installs) — log in
  there and Hyprland starts with the right session/permissions.
  The warning explains the symptom, the cause, and the recovery
  (enable SDDM, switch to its TTY, log in via the GUI).

[0.1.31-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.31-beta

## [0.1.30-beta] — 2026-08-29

### Fixed
- **`fix-mac-super-key.sh` failing on a fresh install with
  `~/.config/hypr/hyprland.conf not found`.** The Hyprland config
  is only created on the first Hyprland start, so users running
  the fix from a TTY (or before logging into the Hyprland
  session for the first time) hit a hard `die`. Replaced the
  `die` with a "create a minimal config with the swap already
  in place" path: the script writes a stub `hyprland.conf` with
  the altwin:swap_alt_win line, exits cleanly, and tells the
  user to log into Hyprland (or run `Hyprland` from a TTY) for
  the swap to take effect. When Hyprland starts for the first
  time, the swap is already in place.

[0.1.30-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.30-beta

## [0.1.29-beta] — 2026-08-29

### Added
- **Warning in next-steps to pick NO encryption in the Omarchy
  wizard's disk step.** The wizard offers LUKS disk encryption
  and, if accepted, the initramfs will prompt for the passphrase
  on every boot. For a personal VM accessed via noVNC this is
  a UX trap: long passphrases are painful to type through a
  browser, the passphrase is unrecoverable if forgotten, and
  there's no way to bypass it from the Proxmox host. The
  warning explains this and recommends ext4/btrfs without
  encryption, relying on Proxmox network isolation for at-rest
  protection.

  (Code change is documentation-only — the script can't
  pre-configure the Omarchy wizard, so the only lever we have
  is the next-steps message.)

[0.1.29-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.29-beta

## [0.1.28-beta] — 2026-08-29

### Fixed
- **Install wizard re-launching on every reboot after install**
  (the user-facing symptom of the v0.1.27-beta boot-order fix).
  Putting ide2 first in the boot order was the right call for the
  *first* boot (so the installer runs at all on a fresh VM with
  an empty disk), but it also means the post-install reboot
  re-runs the wizard, because the ISO is still attached.

  No way to auto-detect "install is done" from the host (the
  wizard doesn't write a marker we can probe, and the QEMU
  guest agent isn't running), so the user has to break the loop
  manually. The fix is in the messaging: a prominent red
  "STOP THE INSTALL LOOP" banner in next-steps, with a single
  one-liner that stops the VM, switches the boot order to
  disk-first, detaches ide2, and starts the VM:

      qm stop <vmid> && qm set <vmid> -boot order=scsi0 -delete ide2 && qm start <vmid>

  The user pastes that on the Proxmox host once the Hyprland
  desktop is up, and from then on the VM boots straight into
  the installed OS. The "Cleanup after install" section was
  also demoted to a sub-block under it (the loop-breaker is
  the important part; freeing the 6 GB ISO is optional).

  The boot-order source comment in `create_vm` also got a
  "SIDE EFFECT" paragraph explaining the loop so the next
  person reading the code understands why we don't just
  auto-detach the ISO.

[0.1.28-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.28-beta

## [0.1.27-beta] — 2026-08-29

### Fixed
- **Omarchy ISO installer not booting on a fresh VM.** The boot
  order was `scsi0;ide2` (disk first, ISO second), on the theory
  that an empty scsi0 would fail and OVMF would fall through to
  the ISO. OVMF/UEFI doesn't reliably do that — on a fresh VM
  with an empty disk, the firmware often just gives up after
  scsi0 fails, the VM never tries ide2, and the ISO installer
  never runs. The VM would either sit at a "no bootable device"
  prompt or, on hosts with a slightly more permissive firmware,
  silently try PXE.

  Changed boot order to `ide2;scsi0` (ISO first, disk second).
  This matches what community-scripts does and is the only
  reliable way to get a first-boot into the Omarchy installer
  on OVMF. After install, the user detaches ide2 (the
  `qm set ... -delete ide2` command in the next-steps "Cleanup
  after install" block), and the firmware falls through to
  scsi0 on subsequent boots.

[0.1.27-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.27-beta

## [0.1.26-beta] — 2026-08-29

### Fixed
- **mac-fix data CD-ROM vanishing during the Omarchy install.**
  Root cause: `main()` called `post_install_cleanup` immediately
  after `start_vm`, before the user had even opened the Proxmox
  console. The cleanup ran `qm set $VMID -delete ide3` on the
  running VM, hot-unplugging the fix CD-ROM while the user was
  still in the live ISO installer. By the time the wizard rebooted
  the VM, the fix was already gone — the user saw the symptom as
  "Omarchy setup reboots and the fix drops", but the reboot was
  a red herring; the script's own auto-cleanup was the cause.

  Removed the `post_install_cleanup` call from `main()`. The
  function still exists (it's documented in the source and listed
  in the new "Cleanup after install" section of the next-steps)
  but the user has to invoke it manually — after the install is
  finished AND the mac-fix has been run.

  Replaced the old "Cleanup" status block in next-steps with a
  "Cleanup after install (manual, when you're done)" section
  showing the exact `qm set ... -delete ideN` and `rm ...` commands
  the user can run when they're ready. Also added a "What was
  attached" block that shows what's currently on the VM's
  CD-ROM buses, so the user can see the state at a glance.

  Easier alternative for the user: re-run `omarchy-vm.sh` with
  the same VMID and let the script's `qm destroy` + recreate
  give them a fully clean state.

[0.1.26-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.26-beta

## [0.1.25-beta] — 2026-08-29

### Changed
- **Replaced the `-vga none` + custom `-device virtio-gpu` in args
  approach with Proxmox's first-class `-vga virtio,memory=512`.**
  This is the supported syntax for adding a virtio-gpu on PVE 7+
  and it sidesteps the whole `-vga none` → `display: none` side-
  effect that's been biting us since v0.1.18. Proxmox's qemu-server
  also sets up the VNC display backend automatically when the VGA
  is something other than `none`, so noVNC just works.

  The args string is now sound-only (HDA controller + codec +
  `-audio driver=none`); the GPU device is no longer duplicated in
  args.

### Fixed
- **Real fix for `noVNC failed to connect to server` on PVE 9.x.**
  v0.1.22 through v0.1.24 were whack-a-mole attempts at working
  around the `-vga none` side-effect (`-display none` removed from
  args in v0.1.22, then `-display vnc` added in v0.1.23, then
  `-display default` in v0.1.24 — the last of which is itself
  rejected on 9.1.4, so the whole approach was a dead end). The
  clean fix is to stop fighting Proxmox's display model and just
  use `-vga virtio` for the GPU.

[0.1.25-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.25-beta

## [0.1.24-beta] — 2026-08-29

### Fixed
- **`qm set ... -display vnc` rejected with "display should be
  default or virtio" on PVE 9.1.4.** The `display` property in
  Proxmox 9.x only accepts `default` or `virtio`; the legacy `vnc`
  / `spice` / `none` values that PVE 8.x accepted were renamed.
  `default` = the host's default display backend (VNC for
  Proxmox's qemu-server — what noVNC connects to). `virtio` = the
  virtio-gpu IS the display (no VNC, the GPU is the only display
  target) — not what we want for a noVNC workflow. Changed
  `-display vnc` to `-display default`. Source comment updated
  to call out the version-dependent value list.

[0.1.24-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.24-beta

## [0.1.23-beta] — 2026-08-29

### Fixed
- **noVNC `failed to connect to server` — true root cause.** v0.1.22-beta
  removed `-display none` from the QEMU args but the VM still came up
  with `display: none` in its config. The actual culprit was
  `qm set ... -vga none` on a line above the args call. Proxmox's
  qemu-server reflects `vga: none` into the VM config and, as a
  side-effect, also flips `display:` to `none` (no VGA → no display
  backend) — which tells Proxmox not to start the VNC server at all.

  Added an explicit `qm set ... -display vnc` immediately after the
  `-vga none` line, restoring the VNC display so noVNC has something
  to connect to. Source comment updated with a note about the
  `-vga none` → `display: none` side-effect and why the order matters.

  (Worth noting: my v0.1.22-beta analysis blamed the args string for
  the same symptom. That was a real bug too — but the `-vga none`
  was the dominant cause, and removing it from args alone wasn't
  enough.)

[0.1.23-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.23-beta

## [0.1.22-beta] — 2026-08-29

### Fixed
- **noVNC `failed to connect to server` after the audio fix.** The
  root cause: the QEMU args passed to `qm set ... -args` included
  `-display none`. Proxmox's qemu-server parses the args string and
  reflects `-display ...` into the VM config's `display:` property,
  so the VM ended up with `display: none` in its config — which
  tells Proxmox not to start a VNC server for the VM at all. noVNC
  then had nothing to connect to.

  Removed `-display none` from the args. Proxmox's qemu-server
  picks the right display backend itself based on the VM config
  (defaults to VNC), and we never needed to override it. Source
  comment updated with a "do NOT re-add `-display none`" warning so
  the next person doesn't make the same mistake. The "opt into 3D"
  snippet in the source comment was also updated to drop the
  `-display none` part.

[0.1.22-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.22-beta

## [0.1.21-beta] — 2026-08-28

### Fixed
- **`no default audio driver available` on `qm start`** (follow-up to
  v0.1.20-beta). The HDA codec device now exists, but QEMU needs an
  explicit audio backend to attach to it. Proxmox hosts ship a QEMU
  build without `pa` (PulseAudio) or `alsa` backends, so the
  default-backend fallback fails. Added `-audio driver=none` to the
  `-args` line. This creates the audio device in the guest — PipeWire
  in Omarchy picks it up as an ALSA sink/source — but doesn't try to
  play on the host (no sound comes out of the Proxmox box, which is
  what we want anyway: the Mac user is on noVNC, which has no SPICE
  audio channel). Comment in the source explains the choice.

### Changed
- **Bumped the in-script `PROXMARCHY_VERSION` constant from
  `0.1.18-beta` to `0.1.21-beta`** so the banner line printed at the
  top of the script's output reports the correct version. (The
  `VERSION` file was also bumped.) The version banner is the
  quickest way to confirm you're on the code you think you're on
  when GitHub's CDN is repeatedly serving stale blobs.

[0.1.21-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.21-beta

## [0.1.20-beta] — 2026-08-28

### Fixed
- **`'intel-hda-duplex' is not a valid device model name` on
  `qm start`.** The HDA codec model name is `hda-duplex`, NOT
  `intel-hda-duplex` (the latter is just wrong; QEMU errors on
  it). Fixed the device name in the `-args` line. The ich9-intel-hda
  controller name is correct as-is.

[0.1.20-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.20-beta

## [0.1.19-beta] — 2026-08-28

### Fixed
- **`PROXMARCHY_VERSION` constant was stuck at `0.1.15-beta`** even
  in v0.1.18-beta. Bumped to `0.1.18-beta` so the version banner
  reports the correct version. (The actual code in v0.1.18-beta
  already had the blob fix; only the cosmetic version label was
  wrong.)
- **GitHub raw CDN + API both serve stale content** (observed
  repeatedly during this rapid release cycle: `?nocache=` query
  strings don't bust the raw CDN cache, and the API also caches
  for several minutes). New `force-fresh.sh` script that
  **clones the repo via the Git protocol** (`git clone --depth 1
  --filter=blob:none --sparse`) and extracts just `omarchy-vm.sh`.
  The Git protocol doesn't go through any HTTP cache layer, so
  the result is the absolute-latest content of `omarchy-vm.sh`
  on `main`, every time. Falls back to the GitHub API, then the
  raw CDN, in order. README now points at this as the most
  reliable one-liner.

[0.1.19-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.19-beta

## [0.1.18-beta] — 2026-08-28

### Fixed
- **`need rutabaga or udmabuf for blob resources` on `qm start`.**
  Even after dropping `venus=true` in v0.1.17-beta, the
  remaining `blob=true` virtio-gpu property requires either
  the host kernel module `udmabuf` (or `modprobe udmabuf`)
  OR the userland `rutabaga` daemon running. On Proxmox
  hosts that don't have `udmabuf` loaded by default and
  don't run `rutabaga`, QEMU refuses to start the VM.
  Dropped `blob=true` entirely; the script now uses plain
  `virtio-gpu,max_outputs=1` (2D-capable, works on every
  Proxmox host). Hyprland runs but software-renders. The
  CHANGELOG/README document how to opt back into 3D by
  loading `udmabuf` and re-adding `blob=true` manually.

[0.1.18-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.18-beta

## [0.1.17-beta] — 2026-08-28

### Fixed
- **`Property 'virtio-gpu-pci.venus' not found` on `qm start`.**
  The `venus=true` virtio-gpu property (Vulkan passthrough,
  QEMU 9.0+) was rejected by some Proxmox 9.x builds that
  ship an older QEMU than the package version suggests.
  Dropped `venus=true` from the virtio-gpu args; `blob=true`
  alone (QEMU 7.1+, the older 3D resource path) is kept. To
  opt into Vulkan passthrough on a host with QEMU ≥ 9.0,
  add `,venus=true` after `blob=true` in the args manually.

[0.1.17-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.17-beta

## [0.1.16-beta] — 2026-08-28

### Changed
- **README: lead the "one-liner (Proxmox host)" section with the
  GitHub API one-liner**, not the `raw.githubusercontent.com` one.
  The raw CDN has been observed to serve stale blobs (the
  `?nocache=$(date +%s)` query-string trick only works for HTTP
  layers that honor query strings; the raw CDN keys on path
  alone). The GitHub API one-liner uses `curl` + `python3` (both
  stock on a Proxmox host) and goes around the CDN entirely. The
  raw one-liner stays documented as a "steady state" fallback.

[0.1.16-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.16-beta

## [0.1.15-beta] — 2026-08-28

### Added
- **Version banner at the top of `omarchy-vm.sh`.** The very
  first runtime output is now `Proxmarchy omarchy-vm.sh
  v0.X.Y-beta  (commit: <short SHA>)`. This makes it easy to tell
  at a glance whether you're running the latest code or a
  cached/stale copy. If the version is wrong, you need to bust
  your curl cache (the `?nocache=$(date +%s)` trick) — some
  HTTP proxies ignore the query string and key only on the
  path, so a strongly random suffix (e.g. `?cb=$RANDOM-$RANDOM`)
  is sometimes needed.

  Also shipped a `PROXMARCHY_GIT_SHA` env-var hook so anyone
  running the script from a local checkout (or a mirror) can
  override the reported SHA.

[0.1.15-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.15-beta

## [0.1.14-beta] — 2026-08-28

### Fixed
- **Double-suffix path bug in `storage_iso_dir`.** The helper
  returned the full path including `/template/iso`, but
  `upload_iso_to_storage()` and `post_install_cleanup()` then
  appended `/template/iso` again, producing the doubled path
  `/var/lib/vz/template/iso/template/iso/proxmarchy-fix.iso` and
  a Proxmox error `volume 'local:iso/proxmarchy-fix.iso' does
  not exist`. The bug had been latent since v0.1.4 (when
  `storage_iso_dir` was first added) but only surfaced in v0.1.12
  when `upload_iso_to_storage()` was re-introduced for the mac
  fix data CD-ROM. The helper now returns the storage's base
  path (e.g. `/var/lib/vz`), and all callers append
  `/template/iso` themselves. `download_omarchy_iso()` had to be
  updated to do the same; the two other callers already did.

[0.1.14-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.14-beta

## [0.1.13-beta] — 2026-08-28

### Fixed
- **`Unknown option: display` / `400 unable to parse option` from
  `qm set -display` and `qm set -gpu`.** Some Proxmox versions /
  `pve-qemu-kvm` package versions don't expose the newer
  `display` and `gpu` qm CLI / API options even though the
  underlying QEMU supports them. The script now passes those
  QEMU flags directly via `qm set ... -args` (`-display none`
  + `-device virtio-gpu,blob=true,venus=true,max_outputs=1`),
  which works on every Proxmox version. The sound device
  (ich9-intel-hda) is also rolled into the same `-args` call,
  so there's only one `-args` per VM.

  Also: dropped the standalone `-vga none` before the `-args`
  call (it was a no-op given the next call replaces everything);
  the new flow is just `qm set --vga none` followed by the
  single combined `qm set --args ...` call.

[0.1.13-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.13-beta

## [0.1.12-beta] — 2026-08-28

### Fixed
- **`upload_iso_to_storage: command not found` at the mac fix
  data ISO upload step.** When v0.1.5 refactored `download_omarchy_iso`
  to handle the Omarchy ISO upload itself, the now-redundant
  `upload_iso_to_storage` helper was deleted. v0.1.11 added a call
  to it from `build_mac_fix_iso()` without bringing the helper
  back, so the data ISO step errored on first run. Re-adds the
  helper (used only by `build_mac_fix_iso()`; the main Omarchy ISO
  is still uploaded inline inside `download_omarchy_iso()`).

[0.1.12-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.12-beta

## [0.1.11-beta] — 2026-08-28

### Added
- **Pre-staged mac fix data CD-ROM when `MAC_USER=yes`.** The
  Proxmox script now builds a tiny ISO 9660 / Joliet / Rock Ridge
  CD-ROM (volume label `FIX`) containing a copy of
  `fix-mac-super-key.sh` as `fix.sh`, attaches it to the VM as
  `ide3`, and detaches + removes it in the post-install cleanup.
  This sidesteps the noVNC clipboard problem: the end user
  doesn't need to paste anything — they just open a terminal in
  Hyprland and type
  ```
  bash /run/media/<user>/FIX/fix.sh
  ```
  (34 characters, very typeable). The post-install "Next steps"
  output now leads with this short path and only mentions the
  longer GitHub one-liner as a fallback if the data CD-ROM is
  gone. Re-adds `genisoimage` to the required tools (it was
  removed in v0.1.6 when cidata was dropped — now needed again
  for the data ISO).

[0.1.11-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.11-beta

## [0.1.10-beta] — 2026-08-28

### Changed
- **Display: modern split for Hyprland performance.** Replaced
  the legacy `-vga virtio,memory=64` (2D-only, 64 MB VRAM,
  software-rendered) with the PVE 8.1+ split form:
  `-display none` + `-gpu virtio,memory=512,accel=hw`. Gives
  Hyprland / Wayland a real 3D-accelerated display with 512 MB
  of VRAM and host-side acceleration, instead of software-rasterizing
  every frame.
- **Sound: Intel HDA via QEMU args.** Added
  `-device ich9-intel-hda -device intel-hda-duplex`. PipeWire
  in Omarchy auto-detects it; `pactl list sinks short` shows it
  immediately. Audible over SPICE (Linux `virt-viewer` / Windows
  MSI); not audible over noVNC (browser VNC has no audio
  channel).
- **Performance: disable memory ballooning.** Added
  `-balloon 0` so Proxmox doesn't reclaim RAM out from under the
  VM. Default 8 GiB is then strictly pinned, which avoids the
  latency spikes the default balloon device causes.
- README: updated the "Tested reference settings (manual)"
  recipe to match the new defaults, and added a "Performance
  + sound rationale" subsection explaining each knob.

[0.1.10-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.10-beta

## [0.1.9-beta] — 2026-08-28

### Added
- **`omarchy-vm.sh` now asks "End user on macOS?" in Advanced
  settings** (default: no). When the answer is yes, the post-install
  "Next steps" output includes a one-liner for the Mac Super-key
  fix (from `fix-mac-super-key.sh`), so the end user has the recipe
  right in their terminal the moment the install finishes — no
  separate lookup, no extra fetch needed beyond the script they
  already trust.
- Templated repo URL constants (`REPO_OWNER`, `REPO_NAME`,
  `REPO_RAW_BASE`) so the one-liner URLs in the script stay in
  sync with a single source of truth.

[0.1.9-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.9-beta

## [0.1.8-beta] — 2026-08-28

### Added
- **New script: `fix-mac-super-key.sh`** — in-VM one-liner that
  swaps Alt and Super inside Hyprland by adding
  `kb_options = altwin:swap_alt_win` to `~/.config/hypr/hyprland.conf`.
  After it runs, `Alt + Space` opens the Omarchy menu, `Alt + Enter`
  opens a terminal, and every other Super+X keybind re-maps to
  Alt+X — which noVNC passes through cleanly on macOS. Backs up
  the config first to
  `~/.config/hypr/backup-super-fix/hyprland.conf.bak.<timestamp>`
  and reloads Hyprland via `hyprctl reload` so the change takes
  effect immediately. Supports `--undo` to restore the backup.
- README: documented the new script and pointed macOS users at it
  as the recommended GUI workflow (in addition to the existing
  SSH-based fallback).

[0.1.8-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.8-beta

## [0.1.7-beta] — 2026-08-28

### Changed
- **README: added a "Console options" section.** Documents the
  noVNC / xterm.js / SPICE tradeoff table and a recommended
  workflow per platform. Highlights that there is no good modern
  macOS Remote Viewer (the official 0.5.7 build doesn't understand
  Proxmox's modern `pvespiceproxy:...` ticket format, and the
  upstream virt-viewer 11.0+ ships Windows-only MSI). For macOS
  users, the recommended path is noVNC for the install + SSH for
  post-install management; the Omarchy menu's "Show keybinds"
  cheat sheet explains what to remap if you need Super-based
  shortcuts in noVNC.

[0.1.7-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.7-beta

## [0.1.6-beta] — 2026-08-28

### Changed
- **Removed the cidata / unattended install option.** The end user
  always follows the Omarchy wizard in the Proxmox console now
  (keyboard → user → disk → confirm). This drops ~140 lines of
  related code: the `build_cidata` function, the `UNATTENDED`
  toggle, the `ide3` cidata attach, the cidata upload call, the
  cidata cleanup branch, and the `genisoimage` dependency. The
  resulting script is simpler, more predictable, and matches the
  out-of-the-box `archlinux-vm.sh` community-scripts pattern
  (one ISO, one wizard). Anyone who wants unattended can still do
  it manually with the official `omarchy.org/manual/unattended-installs/`
  recipe.

[0.1.6-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.6-beta

## [0.1.5-beta] — 2026-08-28

### Fixed
- **Reuse path tried to `cp` a non-existent local file.** When the
  exact Omarchy ISO was already in Proxmox storage, `download_omarchy_iso`
  returned early before copying anything into `TEMP_DIR`. The main
  flow then called `upload_iso_to_storage "$ISO_FILE" "$ISO_FILE"`
  with a bare filename, and `cp` failed with
  `cannot stat 'omarchy-4.0.1.iso': No such file or directory`. The
  `download_omarchy_iso` function now handles the full "discover URL
  → reuse or download+place into Proxmox storage" flow internally,
  and `main` no longer calls `upload_iso_to_storage` for the main
  ISO at all (it still does for the cidata ISO, which is always
  built fresh in `TEMP_DIR`). The reuse path is now a true no-op on
  the filesystem and only prints a single "Reusing ..." line.

[0.1.5-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.5-beta

## [0.1.4-beta] — 2026-08-28

### Changed
- **Reuse the existing Omarchy ISO if it's already in Proxmox storage.**
  Before this fix, the script always re-downloaded the ~6 GB ISO on
  every run. It now checks `<storage_path>/template/iso/<exact-filename>`
  first and skips the download if the same file is already there
  (saves ~6 GB / 1–3 min per re-run on the same node). If a *different*
  `omarchy-*.iso` is sitting there from an older run, the new version
  still downloads and overwrites it.
- Extracted the duplicated storage-path awk into a shared
  `storage_iso_dir` helper used by `download_omarchy_iso`,
  `upload_iso_to_storage`, and `post_install_cleanup` (DRY).

[0.1.4-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.4-beta

## [0.1.3-beta] — 2026-08-28

### Fixed
- **Backtick command substitution in the post-install "next steps" output.**
  One of the final `echo -e` lines in the script wrapped `omarchy update`
  in literal backticks (`` `omarchy update` ``) inside a double-quoted
  string, so bash tried to run `omarchy update` on the Proxmox host
  itself (where it doesn't exist). That surfaced as a confusing
  `omarchy: command not found` + `exit 127` at the very end of a
  otherwise-successful run. The line now uses the same
  `${YW}omarchy update${CL}` variable-coloring pattern as the other
  lines, so it's printed as text and never executed. No other backticks
  in double-quoted strings remain (verified by grep).

[0.1.3-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.3-beta

## [0.1.2-beta] — 2026-08-28

### Fixed
- **Storage split for Proxmox 8/9 defaults.** On a default Proxmox 9
  install, the `local` storage only has `iso, vztmpl, backup` in its
  `content` list — it does NOT have `images`, so `qm set ... -efidisk0
  local:0,...` fails with "storage 'local' does not support vm
  images". The script now picks a separate disk storage that does
  have `images` (typically `local-lvm`), keeps the ISO/cidata on the
  dir-backed `local`, and tells you what it's doing. On a default
  Proxmox 8 install (where `local` is the all-in-one pool) it
  transparently uses the same storage for both.
- The content check is now read from `/etc/pve/storage.cfg` instead
  of `pvesm status` (which doesn't expose the `content` field).

### Changed
- Top-of-script ASCII banner is now a `Proxmarchy` logotype in plain
  ASCII instead of the previous generic banner.

[0.1.2-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.2-beta

## [0.1.1-beta] — 2026-08-28

### Fixed
- **Proxmox VE version check** was rejecting valid patch releases like
  `9.1.4`. The check now extracts `MAJOR.MINOR` from `pveversion` and
  accepts any `8.0–8.x` or `9.0–9.x`. Reported on a Proxmox 9.1.4 host
  minutes after v0.1.0-beta was cut — the one-liner now runs through
  on those nodes without editing the script.

[0.1.1-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.1-beta

## [0.1.0-beta] — 2026-08-28

### Added
- First public beta of `omarchy-vm.sh` — Proxmox-host one-liner that creates a
  full Omarchy VM (UEFI / Q35 / virtio-gpu, virtio-scsi, virtio NIC).
- The script always scrapes `https://omarchy.org/` for the current ISO link
  at run time, so the install is always on the latest release without a
  pinned version.
- Built-in unattended install via Omarchy's official `cidata` (cloud-init
  NoCloud) drive — full config (user / password / hostname / timezone /
  keyboard) + optional SSH key + optional Git author — so the install can
  finish without anyone at the console.
- Optional cleanup of the 6 GB Omarchy ISO from Proxmox storage after
  install (`CLEANUP_ISO=yes` by default; toggleable in Advanced settings).
- `omarchy-in-vm.sh` — in-VM helper that converts an existing plain Arch
  VM to full Omarchy by running the official `omarchy.org/install` (which
  clones `github.com/basecamp/omarchy` and runs its `install.sh`).
- README covering the one-liner, defaults, the cleanup story, and the
  in-VM `omarchy update` flow.

### Notes
- This is a beta. The script has been syntax-checked and the storage.cfg
  parser is unit-tested against a realistic Proxmox config, but it has
  not yet been run end-to-end on a live Proxmox node from this exact
  repo. Please report any issues.

[0.1.0-beta]: https://github.com/jj19/proxmarchy/releases/tag/v0.1.0-beta
