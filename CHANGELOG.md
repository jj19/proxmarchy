# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
