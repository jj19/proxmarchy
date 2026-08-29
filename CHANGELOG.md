# Changelog

All notable changes to this project will be documented in this file.

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
