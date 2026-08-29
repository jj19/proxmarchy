#!/usr/bin/env bash
# omarchy-in-vm.sh — convert a fresh plain Arch VM into full Omarchy
#
# Use this when you ALREADY have an Arch VM (e.g. from
# community-scripts/ProxmoxVE/vm/archlinux-vm.sh) and want to turn it into
# a real, fully-updatable Omarchy install.
#
# The official Omarchy one-liner (boot.sh) lives at:
#   https://omarchy.org/install  →  https://github.com/basecamp/omarchy/blob/master/boot.sh
# That script:
#   1. Sets the Omarchy pacman mirror (stable / rc / dev) based on OMARCHY_REF
#   2. `git clone`s https://github.com/basecamp/omarchy → ~/.local/share/omarchy
#   3. sources `~/.local/share/omarchy/install.sh`, which:
#        - configures the full Hyprland / Wayland / theme / app stack
#        - registers `omarchy update` and `omarchy` CLI commands
#        - registers the pacman repo + hooks for `omarchy-update` to pull
#          the next Omarchy release on demand
#
# So pulling from the official repo IS the way the in-VM install stays
# up to date — both at first install AND on every subsequent `omarchy update`.
#
# Run this on the Arch VM, as a non-root user with sudo.
set -eEo pipefail

# 1. base + git + gum (boot.sh needs git; the Omarchy installer uses gum)
sudo pacman -Syu --noconfirm --needed git gum base-devel

# 2. Run the official Omarchy installer. OMARCHY_REF picks the channel:
#      master / stable (default), rc, dev, edge
#    OMARCHY_REPO lets you point at a fork (default: basecamp/omarchy).
OMARCHY_REF="${OMARCHY_REF:-master}" \
  bash -c "$(curl -fsSL https://omarchy.org/install)"

# 3. After the first reboot, keep the VM current with:
#       omarchy update
#    (or Super + Alt + Space → Update → Omarchy)
