#!/usr/bin/env bash
# build-custom-iso.sh
#
# Builds a Proxmarchy-customized Omarchy ISO that:
#   1. Boots into the same live env as the original Omarchy ISO
#   2. Has a systemd service (proxmarchy-install-detect) that watches
#      /mnt for the install wizard to complete
#   3. When install completes, injects a first-boot service into the
#      installed system that auto-applies the mac-fix on first boot
#   4. The user still walks through the Omarchy wizard interactively,
#      but after install + reboot, the fix is already in place
#
# Usage:
#   ./build-custom-iso.sh [output-iso-path]
#   # default output: ./proxmarchy-omarchy-<version>.iso
#
# Requirements (install on Debian/Ubuntu/Proxmox with `apt`):
#   - xorriso       (xorriso)
#   - squashfs-tools (unsquashfs, mksquashfs)
#   - curl
#   - The Omarchy ISO (auto-downloaded to /tmp if not present)
#
# This script runs as root OR as a regular user with sudo; SUDO is set in preflight.

set -eEuo pipefail

# ── Configuration ──────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_DIR="${SCRIPT_DIR}/iso-customizations"
WORK_DIR="${PROXMARCHY_BUILD_DIR:-/tmp/proxmarchy-iso-build}"
OMARCHY_ISO_URL="${OMARCHY_ISO_URL:-https://iso.omarchy.org/}"
OMARCHY_ISO_VERSION="${OMARCHY_ISO_VERSION:-}"   # auto-detect if empty
ORIGINAL_ISO_CACHE="${PROXMARCHY_ISO_CACHE:-/tmp/omarchy-original.iso}"
OUTPUT_ISO="${1:-}"

# Colors
YW=$'\033[33m'; GN=$'\033[32m'; RD=$'\033[31m'; BL=$'\033[34m'; CL=$'\033[0m'
note() { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$GN" "  ✔ $*" "$CL"; }
warn() { printf '%s%s%s\n' "$YW" "  ⚠ $*" "$CL" >&2; }
die()  { printf '%s%s%s\n' "$RD" "  ✖ $*" "$CL" >&2; exit 1; }

# ── Privilege escalation ─────────────────────────────────────────────
# Run the build as root if you can (common on Proxmox). If you're
# already root, we just skip sudo. If you're not root, we use sudo
# for the mount/loop operations and check that it's available.
if [[ $EUID -eq 0 ]]; then
  SUDO=""
  ok "Running as root (no sudo needed)"
else
  if ! command -v sudo >/dev/null 2>&1; then
    die "Not running as root and 'sudo' is not installed. Either run as root or 'apt install sudo' first."
  fi
  SUDO="sudo"
fi

# ── 0. Preflight ───────────────────────────────────────────────────────
preflight() {
  note "${BL}── Preflight ──${CL}"
  for tool in xorriso unsquashfs mksquashfs curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      die "Missing tool: $tool. Install with: apt install xorriso squashfs-tools curl"
    fi
    ok "$tool"
  done

  if [[ ! -d "$CUSTOM_DIR" ]]; then
    die "Customizations dir not found: $CUSTOM_DIR"
  fi
  for f in \
      "$CUSTOM_DIR/etc/systemd/system/proxmarchy-install-detect.service" \
      "$CUSTOM_DIR/usr/local/bin/proxmarchy-install-detect.sh" \
    ; do
    [[ -f "$f" ]] || die "Missing customization file: $f"
  done
  ok "Customizations present"
  echo
}

# ── 1. Get the original Omarchy ISO ───────────────────────────────────
fetch_original_iso() {
  note "${BL}── Original ISO ──${CL}"

  # If the user pinned a version, use it; otherwise scrape the latest
  # version off the index page.
  local version="${OMARCHY_ISO_VERSION}"
  if [[ -z "$version" ]]; then
    note "  Scraping latest version from ${OMARCHY_ISO_URL}..."
    local index_html
    index_html=$(curl -fsSL "$OMARCHY_ISO_URL")
    version=$(printf '%s\n' "$index_html" | grep -oE 'omarchy-[0-9]+\.[0-9]+\.[0-9]+\.iso' | head -n1 | sed 's/^omarchy-//; s/\.iso$//')
    if [[ -z "$version" ]]; then
      die "Couldn't find a versioned ISO link at ${OMARCHY_ISO_URL}"
    fi
    ok "Latest version: $version"
  else
    ok "Pinned version: $version"
  fi

  local iso_name="omarchy-${version}.iso"
  local url="${OMARCHY_ISO_URL}${iso_name}"
  local target="${ORIGINAL_ISO_CACHE}"
  if [[ "$(basename "$target")" != "$iso_name" ]]; then
    target="/tmp/${iso_name}"
  fi

  if [[ -f "$target" ]] && [[ -s "$target" ]]; then
    ok "Using cached ISO: $target ($(du -h "$target" | awk '{print $1}'))"
    ORIGINAL_ISO="$target"
    OMARCHY_VERSION="$version"
    return
  fi

  note "  Downloading $url ..."
  if ! curl -f#SL -o "$target" "$url"; then
    die "Failed to download $url"
  fi
  ok "Downloaded: $target ($(du -h "$target" | awk '{print $1}'))"
  ORIGINAL_ISO="$target"
  OMARCHY_VERSION="$version"
  echo
}

# ── 2. Stage the build work dir ───────────────────────────────────────
stage_workdir() {
  note "${BL}── Staging work dir ──${CL}"
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR/mnt" "$WORK_DIR/extract" "$WORK_DIR/airootfs"
  ok "Created $WORK_DIR"
  echo
}

# ── 3. Mount + extract the original ISO ───────────────────────────────
extract_iso() {
  note "${BL}── Mounting + extracting ISO ──${CL}"
  if ! ${SUDO} mount -o loop,ro "$ORIGINAL_ISO" "$WORK_DIR/mnt"; then
    die "Failed to mount $ORIGINAL_ISO at $WORK_DIR/mnt"
  fi
  ok "Mounted"

  if ! ${SUDO} cp -a "$WORK_DIR/mnt/." "$WORK_DIR/extract/"; then
    ${SUDO} umount "$WORK_DIR/mnt" || true
    die "Failed to copy ISO contents"
  fi
  ${SUDO} umount "$WORK_DIR/mnt"
  ok "Copied ISO contents to extract/"

  # The archiso squashfs. Modern archiso puts it at arch/x86_64/airootfs.sfs;
  # some variants put it at airootfs.sfs at the root. Handle both.
  local sfs
  sfs=$(find "$WORK_DIR/extract" -name 'airootfs.sfs' -type f | head -n1)
  if [[ -z "$sfs" ]]; then
    die "Couldn't find airootfs.sfs in the ISO"
  fi
  ok "Found airootfs.sfs at: ${sfs#$WORK_DIR/extract/}"

  if ! ${SUDO} unsquashfs -d "$WORK_DIR/airootfs" -no-progress "$sfs"; then
    die "Failed to extract airootfs.sfs"
  fi
  ok "Extracted airootfs to airootfs/"
  AIROOTFS_SFS="$sfs"
  echo
}

# ── 4. Inject customizations into the airootfs ────────────────────────
inject_customizations() {
  note "${BL}── Injecting customizations ──${CL}"

  # The detect service
  local svc_src="$CUSTOM_DIR/etc/systemd/system/proxmarchy-install-detect.service"
  local svc_dst="$WORK_DIR/airootfs/etc/systemd/system/proxmarchy-install-detect.service"
  ${SUDO} install -D -m 0644 "$svc_src" "$svc_dst"
  ok "Service file → ${svc_dst#$WORK_DIR/airootfs/}"

  # The detect script
  local det_src="$CUSTOM_DIR/usr/local/bin/proxmarchy-install-detect.sh"
  local det_dst="$WORK_DIR/airootfs/usr/local/bin/proxmarchy-install-detect.sh"
  ${SUDO} install -D -m 0755 "$det_src" "$det_dst"
  ok "Detect script → ${det_dst#$WORK_DIR/airootfs/}"

  # The fix script (sourced from the same repo as omarchy-vm.sh so the
  # two stay in lock-step). The detect script in the live env will copy
  # this into the installed system at the right time.
  local fix_src="$SCRIPT_DIR/fix-mac-super-key.sh"
  if [[ ! -f "$fix_src" ]]; then
    die "Missing fix-mac-super-key.sh at $fix_src"
  fi
  local fix_dst="$WORK_DIR/airootfs/opt/proxmarchy/fix-mac-super-key.sh"
  ${SUDO} install -D -m 0755 "$fix_src" "$fix_dst"
  ok "Fix script → ${fix_dst#$WORK_DIR/airootfs/}"

  # Enable the service in the live env so it starts on boot
  local want_dst="$WORK_DIR/airootfs/etc/systemd/system/multi-user.target.wants/proxmarchy-install-detect.service"
  ${SUDO} ln -sf "../proxmarchy-install-detect.service" "$want_dst"
  ok "Service enabled in live env (multi-user.target.wants/)"
  echo
}

# ── 5. Repack the airootfs squashfs ──────────────────────────────────
repack_airootfs() {
  note "${BL}── Repacking airootfs.sfs ──${CL}"
  local sfs="$AIROOTFS_SFS"
  local sfs_dir
  sfs_dir=$(dirname "$sfs")
  local sfs_name
  sfs_name=$(basename "$sfs")
  # Move the old one out of the way and write a new one in place
  ${SUDO} mv "$sfs" "${sfs}.bak"
  if ! ${SUDO} mksquashfs "$WORK_DIR/airootfs" "$sfs" -comp xz -noappend -no-progress; then
    ${SUDO} mv "${sfs}.bak" "$sfs"
    die "mksquashfs failed"
  fi
  ${SUDO} rm -f "${sfs}.bak"
  ok "Repacked $(du -h "$sfs" | awk '{print $1}')"
  echo
}

# ── 6. Repackage the ISO ─────────────────────────────────────────────
repackage_iso() {
  note "${BL}── Repackaging ISO ──${CL}"

  if [[ -z "$OUTPUT_ISO" ]]; then
    OUTPUT_ISO="${SCRIPT_DIR}/proxmarchy-omarchy-${OMARCHY_VERSION}.iso"
  fi
  rm -f "$OUTPUT_ISO"

  # xorriso -as mkisofs is the modern way to build a hybrid (UEFI+BIOS)
  # ISO from a directory. The original archiso mkisofs flags are
  # embedded in the source ISO; we use the same approach.
  if ! xorriso -as mkisofs \
      -o "$OUTPUT_ISO" \
      -isohybrid-mbr "$WORK_DIR/extract/isolinux/isohdpfx.bin" \
      -b isolinux/isolinux.bin \
      -c isolinux/boot.cat \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      -eltorito-alt-boot \
      -e EFI/archiso/efiboot.img \
      -no-emul-boot -isohybrid-gpt-basdat \
      "$WORK_DIR/extract" 2>&1 | tail -20; then
    die "xorriso failed"
  fi

  ok "Wrote $(du -h "$OUTPUT_ISO" | awk '{print $1}'): $OUTPUT_ISO"
  echo
}

# ── 7. Cleanup ────────────────────────────────────────────────────────
cleanup() {
  note "${BL}── Cleanup ──${CL}"
  if mountpoint -q "$WORK_DIR/mnt" 2>/dev/null; then
    ${SUDO} umount "$WORK_DIR/mnt" || true
  fi
  if [[ -n "${KEEP_WORKDIR:-}" ]]; then
    note "  Workdir kept: $WORK_DIR (KEEP_WORKDIR=1)"
  else
    ${SUDO} rm -rf "$WORK_DIR"
    ok "Removed workdir $WORK_DIR"
  fi
  echo
}

trap cleanup EXIT

# ── Main ─────────────────────────────────────────────────────────────
main() {
  echo
  note "${BL}Proxmarchy custom ISO builder${CL}"
  note "  Injecting mac-fix auto-apply into a fresh Omarchy ISO"
  echo

  preflight
  fetch_original_iso
  stage_workdir
  extract_iso
  inject_customizations
  repack_airootfs
  repackage_iso
  cleanup

  echo
  ok "${BL}Done.${CL} Custom ISO: ${GN}${OUTPUT_ISO}${CL}"
  echo
  note "  Test it by uploading to Proxmox and running through the wizard:"
  note "    scp ${OUTPUT_ISO} root@mjproxmox:/var/lib/vz/template/iso/"
  note "  Then in omarchy-vm.sh, set ISO_FILE to point at the custom ISO"
  note "  (or just change STORAGE to wherever you uploaded it)."
  echo
}

main "$@"
