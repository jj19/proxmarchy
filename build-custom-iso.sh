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
WORK_DIR="${PROXMARCHY_BUILD_DIR:-/var/tmp/proxmarchy-iso-build}"
# Need ~15 GB of free space for the extracted airootfs + the repacked
# squashfs + the repackaged ISO. /tmp on Proxmox is often a tmpfs sized
# to half the RAM, so it blows through fast; /var/tmp is on the root
# filesystem with much more headroom. Override with
# PROXMARCHY_BUILD_DIR=/path/with/space if neither works.
REQUIRED_FREE_GB="${PROXMARCHY_REQUIRED_FREE_GB:-15}"
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
  for tool in xorriso unsquashfs mksquashfs curl mkfs.fat mcopy mmd; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      case "$tool" in
        mkfs.fat)  pkg="dosfstools" ;;
        mcopy|mmd) pkg="mtools" ;;
        *)         pkg="xorriso squashfs-tools curl" ;;
      esac
      die "Missing tool: $tool. Install with: apt install $pkg"
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

  # Disk-space check. The airootfs extracts to ~12 GB; the rebuilt ISO
  # is another ~6 GB; we want headroom for both + the in-progress
  # squashfs. Bail early with a clear message if the target filesystem
  # doesn't have enough room.
  local free_kb free_gb
  free_kb=$(df -Pk "$WORK_DIR" | awk 'NR==2 {print $4}')
  free_gb=$(( free_kb / 1024 / 1024 ))
  if (( free_gb < REQUIRED_FREE_GB )); then
    die "$WORK_DIR has only ${free_gb} GB free; need at least ${REQUIRED_FREE_GB} GB." \
        "Override the work dir with PROXMARCHY_BUILD_DIR=/path/with/space" \
        "or lower the threshold (NOT recommended) with PROXMARCHY_REQUIRED_FREE_GB=10"
  fi
  ok "${free_gb} GB free at $WORK_DIR (need ${REQUIRED_FREE_GB} GB)"
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

  # Build the right xorriso flags based on what the source ISO actually
  # has. Modern archiso ISOs (including the Omarchy one) are UEFI-only
  # and have no isolinux/ — so the hybrid BIOS+UEFI flags fail. We
  # detect what's there and pass only the relevant ones.
  local xorriso_args=(
    -o "$OUTPUT_ISO"
    -R -J
    # ISO 9660 level 4 lifts the per-file size limit from 4 GiB to ~4 TiB.
    # Required for any ISO that has a > 4 GiB airootfs.sfs — including
    # the Omarchy one. The original Omarchy ISO uses this; we have to
    # match. UEFI firmware supports level 4 universally; older BIOS
    # firmware might not, but we're already UEFI-only.
    -iso-level 4
  )

  # BIOS / isolinux boot (only if the source ISO has it)
  if [[ -f "$WORK_DIR/extract/isolinux/isolinux.bin" ]] \
     && [[ -f "$WORK_DIR/extract/isolinux/isohdpfx.bin" ]]; then
    xorriso_args+=(
      -isohybrid-mbr "$WORK_DIR/extract/isolinux/isohdpfx.bin"
      -b isolinux/isolinux.bin
      -c isolinux/boot.cat
      -no-emul-boot -boot-load-size 4 -boot-info-table
    )
    ok "BIOS (isolinux) boot loader detected"
  else
    note "  No isolinux/ — building UEFI-only ISO"
  fi

  # UEFI boot image. Modern archiso ISOs use one of two mechanisms:
  #   (1) FAT image at EFI/archiso/efiboot.img (older archiso)
  #   (2) Raw EFI binary at EFI/BOOT/BOOTx64.EFI (newer archiso —
  #       Omarchy 4.x is in this camp)
  # xorriso's -e flag accepts both forms. We search for both.
  #
  # Important: the canonical name is `BOOTx64.EFI` (lowercase `x`),
  # which the original Omarchy ISO uses. The ISO filesystem (ISO 9660
  # with Joliet) is case-insensitive so UEFI firmware doesn't care
  # about case, but on the extracted ext4 filesystem (case-sensitive)
  # we need to look for the exact case. We search BOTH and prefer
  # the x86_64 binary (Proxmox VMs are x86_64 — the IA32 binary
  # won't boot on a 64-bit OVMF).
  local efi_img=""
  for candidate in \
      "$WORK_DIR/extract/EFI/archiso/efiboot.img" \
      "$WORK_DIR/extract/EFI/boot/efiboot.img" \
      "$WORK_DIR/extract/EFI/BOOT/BOOTx64.EFI" \
      "$WORK_DIR/extract/EFI/BOOT/BOOTX64.EFI" \
      "$WORK_DIR/extract/EFI/BOOT/BOOTIA32.EFI" \
      "$WORK_DIR/extract/boot/grub/efiboot.img" \
      "$WORK_DIR/extract/boot/grub/x86_64-efi/core.efi" \
    ; do
    if [[ -f "$candidate" ]]; then
      efi_img="$candidate"
      ok "EFI boot image: ${candidate#$WORK_DIR/extract/}"
      break
    fi
  done
  if [[ -z "$efi_img" ]]; then
    # Last-ditch: any .efi or efiboot.img anywhere
    efi_img=$(find "$WORK_DIR/extract" \( -name '*.efi' -o -name 'efiboot.img' -o -name 'BOOTX64.EFI' -o -name 'BOOTx64.EFI' \) -type f 2>/dev/null | head -n1 || true)
    if [[ -n "$efi_img" ]]; then
      warn "Using non-canonical EFI image path: ${efi_img#$WORK_DIR/extract/}"
    fi
  fi
  if [[ -z "$efi_img" ]]; then
    die "No efiboot.img or EFI/BOOT/BOOTx64.EFI found in the source ISO. The ISO might not be UEFI-bootable. Run KEEP_WORKDIR=1 and look at the EFI/ directory in the extracted tree."
  fi
  local rel_efi="${efi_img#$WORK_DIR/extract/}"

  # The El Torito boot catalog is limited to floppy-sized images
  # (1.2/1.44/2.88 MB), but the Omarchy ISO's EFI binary is ~6 MB.
  # We CAN'T use the raw EFI binary as `-e` for El Torito. The fix:
  # build a small FAT image (a valid EFI System Partition) that
  # contains the EFI binary, and use that for the GPT partition
  # via -append_partition. UEFI firmware finds the ESP via GPT
  # and boots from it — El Torito is irrelevant for UEFI.
  local efi_size_kb
  efi_size_kb=$(du -k "$efi_img" | awk '{print $1}')
  if (( efi_size_kb <= 2880 )); then
    # Small enough to use directly as El Torito boot image
    xorriso_args+=(
      -e "$rel_efi"
      -eltorito-alt-boot
      -no-emul-boot
      -append_partition 2 0xef "$efi_img"
      -partition_offset 16
      -iso_mbr_part_type 0xef
    )
    ok "UEFI boot: EFI binary is small enough (${efi_size_kb} KB) — using directly as El Torito + GPT partition"
  else
    # Too big for El Torito. Build a small FAT image containing the
    # EFI binary and use that as the GPT partition.
    note "  EFI binary is ${efi_size_kb} KB — too big for El Torito (2.88 MB limit)"
    note "  Building a small FAT image (EFI System Partition) containing the binary"
    local efiboot_fat="$WORK_DIR/efiboot.img"
    # Round up the FAT image size to the next power of 2 MB, with
    # at least 4 MB of headroom for FAT overhead
    local fat_mb=$(( (efi_size_kb / 1024) + 4 ))
    if (( fat_mb < 32 )); then fat_mb=32; fi
    if ! dd if=/dev/zero of="$efiboot_fat" bs=1M count="$fat_mb" status=none; then
      die "dd failed creating $efiboot_fat"
    fi
    if ! mkfs.fat -F 32 "$efiboot_fat" >/dev/null 2>&1; then
      die "mkfs.fat failed on $efiboot_fat"
    fi
    # mmd/mcopy want the relative path inside the FAT image
    if ! mmd -i "$efiboot_fat" ::/EFI ::/EFI/BOOT 2>/dev/null; then
      die "mmd failed creating EFI/BOOT in $efiboot_fat"
    fi
    if ! mcopy -i "$efiboot_fat" "$efi_img" ::/EFI/BOOT/BOOTX64.EFI; then
      die "mcopy failed copying EFI binary into $efiboot_fat"
    fi
    ok "Built ${fat_mb} MB EFI System Partition: $efiboot_fat"

    # The FAT image must be INSIDE the ISO source tree for xorriso's
    # `-e` flag to find it. archiso puts its efiboot.img at
    # `EFI/archiso/efiboot.img` and uses that exact path with `-e`.
    # We do the same. The file will appear in the ISO at that path
    # AND be used as the El Torito EFI boot image.
    local rel_efiboot="EFI/archiso/efiboot.img"
    local abs_efiboot="$WORK_DIR/extract/${rel_efiboot}"
    mkdir -p "$(dirname "$abs_efiboot")"
    if ! cp -f "$efiboot_fat" "$abs_efiboot"; then
      die "Failed to copy FAT ESP into ISO source tree at $abs_efiboot"
    fi
    ok "FAT ESP placed at ${rel_efiboot} in ISO source tree"

    # Use it as BOTH:
    #   1. A regular El Torito boot image (so OVMF/UEFI firmware on
    #      a CD-ROM device finds it via the boot catalog) — this is
    #      the actual mechanism that makes the ISO bootable in
    #      Proxmox. With `-no-emul-boot` (hard disk emulation) the
    #      2.88 MB floppy size limit doesn't apply.
    #   2. A GPT partition (so the same FAT image is also visible
    #      as a disk-style ESP, matching the original Omarchy ISO's
    #      dual approach for max compat).
    xorriso_args+=(
      -e "$rel_efiboot"
      -no-emul-boot
      -eltorito-alt-boot
      -append_partition 2 0xef "$abs_efiboot"
      -partition_offset 16
      -iso_mbr_part_type 0xef
    )
    ok "UEFI boot configured: El Torito image (at ${rel_efiboot}) + GPT partition"
  fi

  # GPT partition table (required for modern UEFI to recognize the
  # ISO as a bootable disk)
  xorriso_args+=(-isohybrid-gpt-basdat)

  if ! xorriso -as mkisofs "${xorriso_args[@]}" "$WORK_DIR/extract" 2>&1 | tail -20; then
    die "xorriso failed (try running with KEEP_WORKDIR=1 to inspect the extracted tree)"
  fi

  # Verify the boot catalog was actually written. If the boot entry is
  # missing, the user will see "no bootable device" — catch it here.
  if ! xorriso -indev "$OUTPUT_ISO" -report_el_torito plain 2>&1 | grep -qiE 'efi|boot cat'; then
    warn "Boot catalog verification didn't find an EFI entry. The ISO may not be bootable."
    note "  Run: xorriso -indev '$OUTPUT_ISO' -report_el_torito plain"
    note "  to see the full catalog and diagnose."
  else
    ok "Boot catalog verified — ISO should be bootable in UEFI mode"
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
