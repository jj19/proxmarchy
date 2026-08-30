#!/usr/bin/env bash
# omarchy-vm.sh — Proxmox helper-script style installer for Omarchy
#
# Pulls the LATEST official Omarchy ISO from omarchy.org at run time and
# creates a UEFI / Q35 / virtio-gpu Proxmox VM that boots the ISO. The end
# user follows the Omarchy wizard in the Proxmox console (keyboard → user
# → disk → confirm) to install the OS.
#
# Once the wizard finishes, the resulting VM is a full Omarchy install
# with `~/.local/share/omarchy` cloned from
# https://github.com/basecamp/omarchy — so the standard
#   omarchy update
# command (or Super+Alt+Space → Update → Omarchy) keeps it current.
#
# This script is intended to be run on the Proxmox host shell.
#
# Usage (host shell):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jj19/proxmarchy/main/omarchy-vm.sh)"
#
# License: MIT
set -eEo pipefail

# Version banner — printed FIRST so anyone running a cached or stale copy
# can tell at a glance whether they're on the latest. If you see an old
# version here, bust your cache (and the curl command) by appending a
# unique query string:
#   bash -c "$(curl -fsSL '.../omarchy-vm.sh?nocache='$(date +%s))"
# The first line of the script's runtime output should always be:
#   "Proxmarchy omarchy-vm.sh v0.X.Y-beta  (commit: <short SHA>)"
PROXMARCHY_VERSION="0.1.37-beta"
PROXMARCHY_GIT_SHA="${PROXMARCHY_GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
echo "Proxmarchy omarchy-vm.sh ${PROXMARCHY_VERSION}  (commit: ${PROXMARCHY_GIT_SHA})"

# (REPO_OWNER / REPO_NAME / REPO_RAW_BASE are declared further below near
# the other URL constants — keep the comment block above short so the
# script's own usage line shows up first.)

# ----------------------------------------------------------------------------
# 0. Constants
# ----------------------------------------------------------------------------
NSAPP="omarchy-vm"
var_os="omarchy"
var_version="latest"   # pulled live from omarchy.org at run time

# Official download index (we scrape the homepage to always get the latest)
OMARCHY_HOME="https://omarchy.org/"
OMARCHY_ISO_BASE="https://iso.omarchy.org"
OMARCHY_REPO="https://github.com/basecamp/omarchy"

# Where the helper scripts (fix-mac-super-key.sh, etc.) live. Templated
# into the one-liner we print in the post-install "Next steps" message so
# Mac users can remap Super → Alt without leaving the VM console.
REPO_OWNER="jj19"
REPO_NAME="proxmarchy"
REPO_RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"

# Community-scripts style color/icon set
YW=$(printf '\033[33m')
BL=$(printf '\033[36m')
RD=$(printf '\033[01;31m')
BGN=$(printf '\033[4;92m')
GN=$(printf '\033[1;92m')
DGN=$(printf '\033[32m')
CL=$(printf '\033[m')
BOLD=$(printf '\033[1m')
TAB="  "
HOLD=" "

CM="${TAB}✔️${TAB}${CL}"
CROSS="${TAB}✖️${TAB}${CL}"
INFO="${TAB}💡${TAB}${CL}"
OS="${TAB}🖥️${TAB}${CL}"
DISKSIZE="${TAB}💾${TAB}${CL}"
CPUCORE="${TAB}🧠${TAB}${CL}"
RAMSIZE="${TAB}🛠️${TAB}${CL}"
CONTAINERID="${TAB}🆔${TAB}${CL}"
HOSTNAME="${TAB}🏠${TAB}${CL}"
BRIDGE="${TAB}🌉${TAB}${CL}"
DEFAULT="${TAB}⚙️${TAB}${CL}"
MACADDRESS="${TAB}🔗${TAB}${CL}"
VLANTAG="${TAB}🏷️${TAB}${CL}"
CREATING="${TAB}🚀${TAB}${CL}"
ADVANCED="${TAB}🧩${TAB}${CL}"

# ----------------------------------------------------------------------------
# 1. Plumbing (output helpers, traps, cleanup)
# ----------------------------------------------------------------------------
TEMP_DIR="$(mktemp -d)"
pushd "$TEMP_DIR" >/dev/null

msg_info() { echo -ne "${TAB}${YW}${HOLD}$1${HOLD}"; }
msg_ok()   { echo -e "\r\033[K${CM}${GN}$1${CL}"; }
msg_error(){ echo -e "\r\033[K${CROSS}${RD}$1${CL}"; }
header_info() {
  clear
  cat <<'EOF'

  ____                          __         __                                  
 / __ \____ _____ _____ ___  __/ /_  ___  / /_                                 
/ __/ / __ `/ __ `/ __ `__ \/ __ \/ _ \/ __/                                 
/ /___/ /_/ / /_/ / / / / / / /_/ /  __/ /_                                   
/_____/\__,_/\__, /_/ /_/ /_/_.___/\___/\__/                                   
            /____/                                                           
                                                                              
EOF
}

cleanup() { popd >/dev/null 2>&1 || true; rm -rf "$TEMP_DIR"; }
cleanup_vmid() {
  if [[ -n "${VMID:-}" ]] && qm status "$VMID" &>/dev/null; then
    qm stop "$VMID" &>/dev/null || true
    qm destroy "$VMID" &>/dev/null || true
  fi
}
error_handler() {
  local exit_code=$? line_number=$1 command=$2
  msg_error "line ${RD}${line_number}${CL}: exit ${RD}${exit_code}${CL} while executing ${YW}${command}${CL}"
  cleanup_vmid
  exit "$exit_code"
}
trap 'error_handler ${LINENO} "$BASH_COMMAND"' ERR
trap cleanup EXIT

# ----------------------------------------------------------------------------
# 2. Pre-flight
# ----------------------------------------------------------------------------
check_root() {
  if [[ "$(id -u)" -ne 0 || "$(ps -o comm= -p "$PPID")" == "sudo" ]]; then
    clear
    msg_error "Please run this script as root on the Proxmox host."
    exit 1
  fi
}

arch_check() {
  if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    msg_error "This script is for amd64 Proxmox nodes only."
    exit 1
  fi
}

pve_check() {
  if ! command -v pveversion >/dev/null 2>&1; then
    msg_error "pveversion not found. This script must run on a Proxmox VE host."
    exit 1
  fi
  # pveversion emits e.g. "pve-manager/9.1.4/...". The patch digit is what
  # tripped v0.1.0-beta — we only care about major.minor.
  local PVE_VER PVE_MAJOR PVE_MINOR
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  PVE_MAJOR="$(echo "$PVE_VER" | cut -d. -f1)"
  PVE_MINOR="$(echo "$PVE_VER" | cut -d. -f2)"

  if ! [[ "$PVE_MAJOR" =~ ^[0-9]+$ && "$PVE_MINOR" =~ ^[0-9]+$ ]]; then
    msg_error "Could not parse Proxmox VE version from: $PVE_VER"
    exit 1
  fi

  if (( PVE_MAJOR == 8 && PVE_MINOR >= 0 && PVE_MINOR <= 9 )); then
    return 0
  fi
  if (( PVE_MAJOR == 9 && PVE_MINOR >= 0 && PVE_MINOR <= 9 )); then
    return 0
  fi

  msg_error "Proxmox VE ${PVE_VER} not supported (need 8.0–8.x or 9.0–9.x)."
  msg_error "Open an issue: https://github.com/jj19/proxmarchy/issues"
  exit 1
}

require_tools() {
  for t in qm pvesm whiptail curl openssl genisoimage awk sed numfmt du; do
    command -v "$t" >/dev/null 2>&1 || {
      msg_error "Missing required tool: $t  (apt install genisoimage xorriso)"
      exit 1
    }
  done
}

ssh_check() {
  if [[ -n "${SSH_CLIENT:-}" ]] && command -v pveversion >/dev/null 2>&1; then
    if ! whiptail --backtitle "Proxmox VE Helper Scripts" --defaultno \
        --title "SSH DETECTED" --yesno \
        "It's suggested to use the Proxmox shell instead of SSH.\nProceed anyway?" 10 62; then
      clear; exit 0
    fi
  fi
}

# ----------------------------------------------------------------------------
# 3. Settings: default + advanced (community-scripts style)
# ----------------------------------------------------------------------------
get_valid_nextid() {
  local try
  try=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
  while true; do
    if [[ -f "/etc/pve/qemu-server/${try}.conf" ]] || [[ -f "/etc/pve/lxc/${try}.conf" ]]; then
      try=$((try+1)); continue
    fi
    if lvs --noheadings -o lv_name 2>/dev/null | grep -qE "(^|[-_])${try}($|[-_])"; then
      try=$((try+1)); continue
    fi
    break
  done
  echo "$try"
}

default_settings() {
  VMID=$(get_valid_nextid)
  HN="omarchy"
  MACHINE="-machine q35"
  CPU_TYPE="-cpu host"
  CORE_COUNT=4
  RAM_SIZE=8192
  DISK_SIZE=100
  DISK_CACHE=""
  BRG="vmbr0"
  MAC="02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')"
  VLAN=""
  MTU=""
  START_VM="yes"
  CLEANUP_ISO="yes"   # remove the 6 GB Omarchy ISO from Proxmox storage after install
  MAC_USER="no"       # show the noVNC Super-key fix in the next-steps message?
  METHOD="default"
  METHOD_DESC="Default"
  echo -e "${CONTAINERID}${BOLD}${DGN}VM ID: ${BGN}${VMID}${CL}"
  echo -e "${CONTAINERTYPE:-${OS}}${BOLD}${DGN}Machine: ${BGN}q35 (UEFI)${CL}"
  echo -e "${OS}${BOLD}${DGN}CPU: ${BGN}host${CL}"
  echo -e "${CPUCORE}${BOLD}${DGN}Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${RAMSIZE}${BOLD}${DGN}RAM: ${BGN}${RAM_SIZE} MiB${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk: ${BGN}${DISK_SIZE} GiB${CL}"
  echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
  echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${DEFAULT}${BOLD}${DGN}Install: ${BGN}Omarchy wizard (in the Proxmox console)${CL}"
  echo -e "${GATEWAY:-${DEFAULT}}${BOLD}${DGN}Start VM when done: ${BGN}yes${CL}"
  echo -e "${DEFAULT}${BOLD}${DGN}Remove Omarchy ISO from storage after install: ${BGN}yes${CL}  ${YW}(saves ~6 GB)${CL}"
  echo -e "${DEFAULT}${BOLD}${DGN}End user on macOS? ${BGN}no${CL}  ${YW}(toggle in Advanced to enable the Super-key fix)${CL}"
}

advanced_settings() {
  METHOD="advanced"
  METHOD_DESC="Advanced"
  [[ -z "${VMID:-}" ]] && VMID=$(get_valid_nextid)

  # VMID
  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
        "Set Virtual Machine ID" 8 58 "$VMID" --title "VIRTUAL MACHINE ID" \
        --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [[ -z "$VMID" ]] && VMID=$(get_valid_nextid)
      if pct status "$VMID" &>/dev/null || qm status "$VMID" &>/dev/null; then
        echo -e "${CROSS}${RD} ID $VMID is already in use${CL}"; sleep 2; continue
      fi
      echo -e "${CONTAINERID}${BOLD}${DGN}VM ID: ${BGN}$VMID${CL}"; break
    else exit_script; fi
  done

  # Hostname
  if HN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
      "Set Hostname" 8 58 "$HN" --title "HOSTNAME" \
      --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    [[ -z "$HN" ]] && HN="omarchy"
    HN=$(echo "${HN,,}" | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')
    echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"
  else exit_script; fi

  # Cores
  while true; do
    if CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
        "Allocate CPU Cores" 8 58 "$CORE_COUNT" --title "CORE COUNT" \
        --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [[ -z "$CORE_COUNT" ]] && CORE_COUNT=4
      if [[ "$CORE_COUNT" =~ ^[1-9][0-9]*$ ]]; then
        echo -e "${CPUCORE}${BOLD}${DGN}Cores: ${BGN}$CORE_COUNT${CL}"; break
      fi
      whiptail --msgbox "Cores must be a positive integer." 8 58
    else exit_script; fi
  done

  # RAM
  while true; do
    if RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
        "Allocate RAM in MiB (Omarchy needs at least 4096)" 8 58 "$RAM_SIZE" \
        --title "RAM" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [[ -z "$RAM_SIZE" ]] && RAM_SIZE=8192
      if [[ "$RAM_SIZE" =~ ^[1-9][0-9]*$ ]] && (( RAM_SIZE >= 4096 )); then
        echo -e "${RAMSIZE}${BOLD}${DGN}RAM: ${BGN}$RAM_SIZE MiB${CL}"; break
      fi
      whiptail --msgbox "RAM must be an integer ≥ 4096 MiB (recommended 8192+)." 8 58
    else exit_script; fi
  done

  # Disk
  while true; do
    if DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
        "Disk size in GiB (Omarchy recommends 100+)" 8 58 "$DISK_SIZE" \
        --title "DISK SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      [[ -z "$DISK_SIZE" ]] && DISK_SIZE=100
      if [[ "$DISK_SIZE" =~ ^[1-9][0-9]*$ ]] && (( DISK_SIZE >= 64 )); then
        echo -e "${DISKSIZE}${BOLD}${DGN}Disk: ${BGN}${DISK_SIZE} GiB${CL}"; break
      fi
      whiptail --msgbox "Disk must be an integer ≥ 64 GiB (recommended 100+)." 8 58
    else exit_script; fi
  done

  # Bridge
  if BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
      "Bridge (e.g. vmbr0)" 8 58 "$BRG" --title "BRIDGE" \
      --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    [[ -z "$BRG" ]] && BRG="vmbr0"
    echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}$BRG${CL}"
  else exit_script; fi

  # MAC
  if MAC=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox \
      "MAC address (blank = random)" 8 58 "$MAC" --title "MAC ADDRESS" \
      --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
    if [[ -n "$MAC" ]] && ! [[ "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
      whiptail --msgbox "Invalid MAC, using random." 8 58
      MAC="02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')"
    fi
    [[ -z "$MAC" ]] && MAC="02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')"
    echo -e "${MACADDRESS}${BOLD}${DGN}MAC: ${BGN}$MAC${CL}"
  else exit_script; fi

  # Install mode is fixed: end user follows the Omarchy wizard in the
  # Proxmox console. (No cidata/unattended option — keep it simple.)

  # Clean up the Omarchy ISO from Proxmox storage after the VM is built?
  # The ISO is 6 GB; we already have a copy in Proxmox storage, and the VM
  # doesn't need it after install (boot order is scsi0;ide2, disk wins).
  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "REMOVE ISO AFTER INSTALL" \
      --yesno "Remove the Omarchy ISO from Proxmox storage after the VM is built?\n\nDefault = yes (frees ~6 GB).\nChoose 'No' if you want to keep it to re-install or build another VM." 14 62; then
    CLEANUP_ISO="yes"
    echo -e "${DEFAULT}${BOLD}${DGN}Remove Omarchy ISO after install: ${BGN}yes${CL}"
  else
    CLEANUP_ISO="no"
    echo -e "${DEFAULT}${BOLD}${DGN}Remove Omarchy ISO after install: ${BGN}no${CL}"
  fi

  # Is the end user on macOS? The browser noVNC console on macOS often loses
  # the Super/Cmd key (browser + macOS claim it for system shortcuts), which
  # breaks Omarchy's Super+Space menu, Super+Enter terminal, etc. If yes,
  # the next-steps message will include a one-liner to remap Super → Alt
  # inside Hyprland so everything just works.
  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "END USER ON MACOS?" \
      --yesno "Will the end user be connecting to this VM from macOS via the Proxmox browser (noVNC) console?\n\nThe browser noVNC client on macOS often loses the Super/Cmd key, which breaks Omarchy's Super+Space menu and other Super keybinds.\n\nIf 'Yes', the next-steps output will include a one-liner the user can run inside the VM to remap Super → Alt." 16 70; then
    MAC_USER="yes"
    echo -e "${DEFAULT}${BOLD}${DGN}End user on macOS: ${BGN}yes${CL}  ${YW}(Super→Alt fix will be in next-steps)${CL}"
  else
    MAC_USER="no"
    echo -e "${DEFAULT}${BOLD}${DGN}End user on macOS: ${BGN}no${CL}"
  fi

  # Start VM?
  if whiptail --yesno "Start VM when finished?" 10 58; then
    START_VM="yes"
  else
    START_VM="no"
  fi
  echo -e "${DEFAULT}${BOLD}${DGN}Start VM when done: ${BGN}${START_VM}${CL}"
}

start_script() {
  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" \
      --yesno "Use Default Settings?" --no-button Advanced 10 58; then
    header_info
    echo -e "${DEFAULT}${BOLD}${BL}Using Default Settings${CL}"
    default_settings
  else
    header_info
    echo -e "${ADVANCED}${BOLD}${RD}Using Advanced Settings${CL}"
    advanced_settings
  fi
}

exit_script() {
  clear
  echo -e "\n${CROSS}${RD}User exited script${CL}\n"
  exit 0
}

# ----------------------------------------------------------------------------
# 4. Storage pick
# ----------------------------------------------------------------------------
# Check whether a Proxmox storage has 'images' in its content types.
# 'pvesm status' doesn't expose the content list, so we read it from
# /etc/pve/storage.cfg. 'images' is the content type required for VM
# disks (and EFI disks) in PVE 8/9.
storage_supports_images() {
  local st="$1"
  local content_csv
  content_csv=$(awk -v s="$st" '
    $1 ~ /^[a-zA-Z0-9_.-]+:$/ {
      current = $2
      in_storage = (current == s)
      next
    }
    in_storage && $1 == "content" {
      # emit just the comma-separated content list, no whitespace, no key
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      sub(/^content[[:space:]]+/, "")
      gsub(/[[:space:]]/, "")
      print
      exit
    }
  ' /etc/pve/storage.cfg 2>/dev/null)
  [[ ",$content_csv," == *",images,"* ]] && echo "yes"
}

pick_storage() {
  local STORAGE_MENU=()
  local VALID TAG TYPE FREE ITEM OFFSET MSG_MAX_LENGTH=0
  # -content iso: only storages that can hold ISO files
  while read -r line; do
    TAG=$(echo "$line" | awk '{print $1}')
    TYPE=$(echo "$line" | awk '{printf "%-10s", $2}')
    FREE=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf("%9sB", $6)}')
    ITEM="  Type: $TYPE Free: $FREE "
    OFFSET=2
    if (( ${#ITEM} + OFFSET > MSG_MAX_LENGTH )); then
      MSG_MAX_LENGTH=$(( ${#ITEM} + OFFSET ))
    fi
    STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
  done < <(pvesm status -content iso 2>/dev/null | awk 'NR>1')
  VALID=$(pvesm status -content iso 2>/dev/null | awk 'NR>1')
  if [[ -z "$VALID" ]]; then
    msg_error "Unable to detect a storage pool with ISO support (e.g. 'local')."
    msg_error "Add one in Datacenter → Storage → Add → Directory."
    exit 1
  elif (( ${#STORAGE_MENU[@]} / 3 == 1 )); then
    STORAGE="${STORAGE_MENU[0]}"
  else
    while [[ -z "${STORAGE:+x}" ]]; do
      STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "ISO Storage" --radiolist \
        "Which storage pool should hold the Omarchy ISO?\nPick a dir-backed one — script copies the file into it directly." \
        16 $((MSG_MAX_LENGTH + 23)) 6 \
        "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit_script
    done
  fi
  msg_ok "ISO storage: ${BL}${STORAGE}${CL}"
}

# Proxmox 8/9 default installs split things: 'local' is dir-backed and holds
# ISOs, 'local-lvm' is LVM-thin and holds VM images. They can't be the same
# pool, so if the ISO storage doesn't also have 'images' in its content list,
# we need to pick a separate disk storage. This was the v0.1.0-beta bug that
# surfaced as "storage 'local' does not support vm images" on 9.1.x.
pick_disk_storage() {
  if [[ "$(storage_supports_images "$STORAGE")" == "yes" ]]; then
    DISK_STORAGE="$STORAGE"
    msg_ok "Disk storage: ${BL}${DISK_STORAGE}${CL}  ${YW}(same pool as ISO — has images content)${CL}"
    return 0
  fi

  # ISO storage does NOT support VM images. Auto-pick a sensible default
  # (the typical 'local-lvm') and fall back to a whiptail prompt.
  local IMG_MENU=() VALID TAG TYPE FREE ITEM OFFSET MSG_MAX_LENGTH=0
  while read -r line; do
    TAG=$(echo "$line" | awk '{print $1}')
    TYPE=$(echo "$line" | awk '{printf "%-10s", $2}')
    FREE=$(echo "$line" | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf("%9sB", $6)}')
    ITEM="  Type: $TYPE Free: $FREE "
    OFFSET=2
    if (( ${#ITEM} + OFFSET > MSG_MAX_LENGTH )); then
      MSG_MAX_LENGTH=$(( ${#ITEM} + OFFSET ))
    fi
    IMG_MENU+=("$TAG" "$ITEM" "OFF")
  done < <(pvesm status -content images 2>/dev/null | awk 'NR>1')
  VALID=$(pvesm status -content images 2>/dev/null | awk 'NR>1')
  if [[ -z "$VALID" ]]; then
    msg_error "Storage '${STORAGE}' holds the ISO, but no storage on this node has 'images' content for the VM disk."
    msg_error "Add one in Datacenter → Storage → Add (LVM-Thin, ZFS, Ceph, or directory-with-images)."
    exit 1
  fi

  # Prefer local-lvm as the default if it exists, else the only one available.
  local DEFAULT_DISK=""
  for tag in "${IMG_MENU[@]}"; do
    [[ "$tag" == "local-lvm" ]] && DEFAULT_DISK="local-lvm"
  done
  if [[ -z "$DEFAULT_DISK" ]]; then
    DEFAULT_DISK="${IMG_MENU[0]}"
  fi

  if (( ${#IMG_MENU[@]} / 3 == 1 )); then
    DISK_STORAGE="${IMG_MENU[0]}"
  else
    while [[ -z "${DISK_STORAGE:+x}" ]]; do
      DISK_STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" \
        --title "Disk Storage" --radiolist \
        "Storage '${STORAGE}' holds ISOs but NOT VM disks.\n\nPick the pool for the ${DISK_SIZE}G Omarchy disk + 4M EFI disk\n(typical: 'local-lvm' on Proxmox 8/9 defaults)." \
        20 $((MSG_MAX_LENGTH + 23)) 6 \
        "${IMG_MENU[@]}" 3>&1 1>&2 2>&3) || exit_script
    done
  fi
  msg_ok "Disk storage: ${BL}${DISK_STORAGE}${CL}  ${YW}(ISO stays on '${STORAGE}')${CL}"
}

# ----------------------------------------------------------------------------
# 4b. Resolve the on-disk path of a Proxmox storage's `path` line.
#     Returns the storage's filesystem root (e.g. "/var/lib/vz") for
#     dir-backed storages, or empty if the storage has no local
#     filesystem path (LVM-thin / ZFS / Ceph / etc.).
#
#     Callers should append "/template/iso" themselves to get the
#     actual ISO directory, and then a filename. Doing it this way
#     (rather than baking the suffix into the helper) avoids a
#     double-suffix bug where callers would also append
#     "/template/iso" and end up at ".../template/iso/template/iso/".
# ----------------------------------------------------------------------------
storage_iso_dir() {
  local st="$1"
  awk -v s="$st" '
    $1 ~ /^[a-zA-Z0-9_.-]+:$/ {
      current = $2
      in_storage = (current == s)
      next
    }
    in_storage && $1 == "path" {
      print $2
      exit
    }
  ' /etc/pve/storage.cfg 2>/dev/null
}

# ----------------------------------------------------------------------------
# 4c. Upload a file into a Proxmox storage's ISO directory.
#     Used by build_mac_fix_iso() for the data CD-ROM. Errors out with
#     a clear message if the chosen storage has no local filesystem path
#     (LVM-thin / ZFS / Ceph) — same constraint as the main ISO upload.
# ----------------------------------------------------------------------------
upload_iso_to_storage() {
  local SRC_FILE="$1"
  local DEST_NAME="$2"
  local STORAGE="$3"

  local ISO_DIR
  ISO_DIR=$(storage_iso_dir "$STORAGE")
  if [[ -n "$ISO_DIR" ]]; then
    mkdir -p "${ISO_DIR}/template/iso"
    cp -f "$SRC_FILE" "${ISO_DIR}/template/iso/${DEST_NAME}"
    msg_ok "Stored ${BL}${DEST_NAME}${CL} in ${BL}${ISO_DIR}/template/iso/${CL}"
    return 0
  fi
  msg_error "Storage '${STORAGE}' has no local path (LVM-thin / ZFS / Ceph / etc.)."
  msg_error "Pick a dir-backed storage for the data ISO (typical: 'local')."
  exit 1
}

# ----------------------------------------------------------------------------
# 5. Pull the latest Omarchy ISO (always fresh — but reuse if already there)
# ----------------------------------------------------------------------------
download_omarchy_iso() {
  msg_info "Fetching the latest Omarchy ISO URL from ${OMARCHY_HOME}"
  local ISO_URL
  ISO_URL=$(curl -fsSL "$OMARCHY_HOME" \
    | grep -oE 'https://iso\.omarchy\.org/omarchy-[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?\.iso' \
    | head -n1 || true)
  if [[ -z "$ISO_URL" ]]; then
    # Fallback: scrape for any omarchy ISO URL
    ISO_URL=$(curl -fsSL "$OMARCHY_HOME" \
      | grep -oE 'https://iso\.omarchy\.org/omarchy[^"'"'"' ]+\.iso' \
      | head -n1 || true)
  fi
  if [[ -z "$ISO_URL" ]]; then
    msg_error "Could not discover the latest Omarchy ISO URL from ${OMARCHY_HOME}"
    msg_error "Check that the host can reach omarchy.org / iso.omarchy.org"
    exit 1
  fi
  msg_ok "Latest Omarchy ISO: ${BL}${ISO_URL}${CL}"
  ISO_FILE="$(basename "$ISO_URL")"

  # Resolve the target path inside Proxmox storage
  local ISO_DIR TARGET
  ISO_DIR=$(storage_iso_dir "$STORAGE")
  if [[ -z "$ISO_DIR" ]]; then
    msg_error "Storage '${STORAGE}' has no local path (LVM-thin / ZFS / Ceph / etc.)."
    msg_error "Pick a dir-backed storage for the ISO (typical: 'local')."
    exit 1
  fi
  TARGET="${ISO_DIR}/template/iso/${ISO_FILE}"

  # If the exact same ISO is already in the chosen Proxmox storage, reuse
  # it instead of re-downloading 6 GB. Catches the "I just ran this 10
  # minutes ago" case. If a *different* omarchy-*.iso is sitting there
  # from an older run, the download path below will overwrite it.
  if [[ -f "$TARGET" ]]; then
    local SIZE
    SIZE=$(du -h "$TARGET" | awk '{print $1}')
    msg_ok "Reusing ${BL}${ISO_FILE}${CL} already in Proxmox storage (${BOLD}${SIZE}${CL}) — skipping download"
    return 0
  fi

  # Download into TEMP_DIR (we're pushd'd there), then copy into Proxmox
  # storage. Doing the copy HERE (not in main) means the rest of the
  # script can just trust that the file is at the target path and never
  # has to think about TEMP_DIR vs. Proxmox storage again.
  msg_info "Downloading ${ISO_FILE}"
  if ! curl -f#SL -o "$ISO_FILE" "$ISO_URL"; then
    msg_error "ISO download failed: $ISO_URL"
    exit 1
  fi
  echo -en "\e[1A\e[0K"
  msg_ok "Downloaded ${BL}${ISO_FILE}${CL} (${BOLD}$(du -h "$ISO_FILE" | awk '{print $1}')${CL})"

  msg_info "Storing ISO in Proxmox storage"
  mkdir -p "${ISO_DIR}/template/iso"
  if ! cp -f "$ISO_FILE" "$TARGET"; then
    msg_error "Failed to copy ISO into Proxmox storage at $TARGET"
    exit 1
  fi
  msg_ok "Stored ISO in ${BL}${TARGET}${CL}"
}

# ----------------------------------------------------------------------------
# 6. (no cidata / unattended option — the end user follows the Omarchy
#    ISO wizard in the Proxmox console)
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
# 6b. Mac fix data ISO (only when MAC_USER=yes)
#
# Why: noVNC in the browser has no clipboard, so the end user can't
# paste a long one-liner into the VM terminal. This function builds a
# tiny data CD-ROM that auto-mounts in the installed Omarchy under
# /run/media/<user>/FIX/fix.sh, so the user just types:
#
#     bash /run/media/omarchy/FIX/fix.sh
#
# (or runs the file from the file manager — double-click).
#
# The fix is sourced directly from the same proxmarchy repo the main
# script came from, so the two stay in lock-step on every run.
# ----------------------------------------------------------------------------
build_mac_fix_iso() {
  local FIX_DIR DATA_ISO
  FIX_DIR="$(mktemp -d)"
  DATA_ISO="${TEMP_DIR}/proxmarchy-fix.iso"

  # Pull the latest fix script straight from the repo
  msg_info "Fetching the mac fix script from ${REPO_RAW_BASE}/fix-mac-super-key.sh"
  if ! curl -fsSL "${REPO_RAW_BASE}/fix-mac-super-key.sh" -o "${FIX_DIR}/fix.sh"; then
    msg_error "Failed to fetch the fix script. The VM will still be created —"
    msg_error "the user can run the fix later via the GitHub one-liner."
    rm -rf "$FIX_DIR"
    return 1
  fi
  chmod +x "${FIX_DIR}/fix.sh"
  msg_ok "Fetched fix script"

  # Build a tiny ISO 9660 (Joliet + Rock Ridge for filename/perm support)
  # Volume label "FIX" so the user can find it at /run/media/<user>/FIX/
  msg_info "Building data ISO (label=FIX)"
  if ! genisoimage -V "FIX" -joliet -rock -o "$DATA_ISO" "$FIX_DIR" >/dev/null 2>&1; then
    msg_error "genisoimage failed. The VM will still be created —"
    msg_error "the user can run the fix later via the GitHub one-liner."
    rm -rf "$FIX_DIR"
    return 1
  fi
  rm -rf "$FIX_DIR"
  msg_ok "Built $(du -h "$DATA_ISO" | awk '{print $1}') data ISO"

  # Upload to the same Proxmox storage as the main ISO
  upload_iso_to_storage "$DATA_ISO" "proxmarchy-fix.iso" "$STORAGE"
  msg_ok "Uploaded to Proxmox storage as proxmarchy-fix.iso"
}

# ----------------------------------------------------------------------------
# 6c. cidata ISO (cloud-init NoCloud datasource) — LEGACY, NOT CALLED
#
# Historical context: v0.1.32-beta and v0.1.33-beta attached a cidata
# drive to the VM so cloud-init could auto-apply the mac-fix on first
# boot of the installed system. This turned out to be broken for the
# Omarchy install path: the Omarchy ISO is a LIVE environment, and the
# live session's cloud-init detects the cidata drive (label "cidata")
# and processes it during the wizard — i.e. on the live filesystem,
# not the installed one. By the time the user finished the wizard and
# rebooted into the installed system, cloud-init had already "consumed"
# the cidata and the marker file was on the (now-orphaned) live
# filesystem. The auto-fix never actually ran on the installed system.
#
# The function is kept here (and the build artifacts referenced by
# `complete_install`'s cleanup paths) for backward compat with VMs
# that were created with v0.1.32-beta or v0.1.33-beta. Do NOT call
# this from `main()` — `--complete` will tidy up any leftover
# proxmarchy-cidata.iso in Proxmox storage.
#
# The "real" auto-fix would require either a custom Omarchy ISO with
# a systemd first-boot service, or modifying the Omarchy install
# itself. Both are v0.2.0+ work.
# ----------------------------------------------------------------------------
build_cidata_iso() {
  local CIDATA_DIR DATA_ISO INSTANCE_ID
  CIDATA_DIR="$(mktemp -d)"
  DATA_ISO="${TEMP_DIR}/proxmarchy-cidata.iso"
  INSTANCE_ID="proxmarchy-${VMID}-$(date +%s)"

  # user-data: cloud-config that runs on first boot.
  # - packages: try to install qemu-guest-agent (optional; || true in runcmd)
  # - runcmd: enable the agent, apply the mac-fix, write a marker file
  cat > "${CIDATA_DIR}/user-data" <<EOF
#cloud-config
# Proxmarchy post-install: applies the mac-fix on first boot via cloud-init.
# If cloud-init isn't installed in the guest, this drive is just an
# unread CD-ROM and you'll need to apply the fix manually.

packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable --now qemu-guest-agent 2>/dev/null || true
  - bash -c "\$(curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/fix-mac-super-key.sh)" 2>/dev/null || true
  - touch /var/lib/proxmarchy-install-complete
EOF

  # meta-data: instance ID + hostname (required for cloud-init)
  cat > "${CIDATA_DIR}/meta-data" <<EOF
instance-id: ${INSTANCE_ID}
local-hostname: ${HN}
EOF

  # Build the ISO with volume label "cidata" (cloud-init's NoCloud
  # datasource looks for this label)
  msg_info "Building cidata ISO (label=cidata)"
  if ! genisoimage -V "cidata" -joliet -rock -o "$DATA_ISO" "$CIDATA_DIR" >/dev/null 2>&1; then
    msg_error "genisoimage failed for cidata. The VM will still be created —"
    msg_error "the user can apply the fix manually via the GitHub one-liner."
    rm -rf "$CIDATA_DIR"
    return 1
  fi
  rm -rf "$CIDATA_DIR"
  msg_ok "Built $(du -h "$DATA_ISO" | awk '{print $1}') cidata ISO"

  upload_iso_to_storage "$DATA_ISO" "proxmarchy-cidata.iso" "$STORAGE"
  msg_ok "Uploaded to Proxmox storage as proxmarchy-cidata.iso"
}

# ----------------------------------------------------------------------------
# 7. Create the VM
# ----------------------------------------------------------------------------
create_vm() {
  msg_info "Creating Omarchy VM ${VMID} (${HN})"
  qm create "$VMID" \
    -agent 1 \
    -machine q35 \
    -tablet 0 \
    -localtime 1 \
    -bios ovmf \
    -cpu host \
    -cores "$CORE_COUNT" \
    -memory "$RAM_SIZE" \
    -name "$HN" \
    -tags community-script,omarchy \
    -net0 "virtio,bridge=${BRG},macaddr=${MAC}${VLAN}${MTU}" \
    -onboot 1 \
    -ostype l26 \
    -scsihw virtio-scsi-single

  # EFI disk (no Secure Boot pre-enrolled keys — Hyprland/limine path)
  qm set "$VMID" -efidisk0 "${DISK_STORAGE}:0,efitype=4m,pre-enrolled-keys=0" >/dev/null

  # ── Display ────────────────────────────────────────────────────────────
  # Use Proxmox's first-class `-vga virtio` option. This:
  #   - Creates a virtio-gpu device (Hyprland's preferred display type)
  #   - Allocates 512 MiB of VRAM (generous; Hyprland likes lots of VRAM)
  #   - Sets up the VNC display backend automatically — no need to
  #     fight the `-vga none` → `display: none` side-effect we hit
  #     on v0.1.18 through v0.1.24
  #   - Works on all modern Proxmox versions (the option has been
  #     first-class since PVE 7.x)
  #
  # We intentionally do NOT pass 3D flags (blob=true, venus=true) —
  # see CHANGELOG v0.1.17 / v0.1.18 for why and how to opt back in
  # (modprobe udmabuf on the host, then re-add ,blob=true manually).
  qm set "$VMID" -vga virtio,memory=512 >/dev/null

  # Serial console (handy for Proxmox xterm.js / debugging)
  qm set "$VMID" -serial0 socket >/dev/null

  # ── Sound via QEMU args (HDA isn't a first-class Proxmox option) ────
  # The args string ONLY contains sound + audio-backend now. The GPU
  # device is handled by `-vga virtio` above; we no longer need to
  # add `-device virtio-gpu,max_outputs=1` here.
  #
  # Note on the HDA args:
  #   -audio driver=none                       — tell QEMU which audio
  #     backend to use for any hda-* device on the host. `none` means
  #     "create the device but don't try to play it on the host" — the
  #     guest still sees the audio device (PipeWire in Omarchy picks it
  #     up as an ALSA sink/source), but no actual sound comes out. This
  #     avoids the "no default audio driver available" error that
  #     Proxmox hosts hit because the QEMU build typically doesn't have
  #     pa/alsa backends compiled in, and the Mac user is on noVNC
  #     (no SPICE audio channel) anyway.
  #   -device ich9-intel-hda,id=sound0,bus=pci.0,addr=0x18   — the HDA
  #     controller (I/O + interrupt registers). The PCI addr 0x18 is a
  #     common slot for the HDA on ICH9; 0x1b is another valid choice.
  #   -device hda-duplex,id=sound0-codec0,bus=sound0.0,cad=0  — the
  #     HDA codec (the actual audio I/O). The model name is
  #     `hda-duplex` (NOT `intel-hda-duplex` — that's wrong and QEMU
  #     errors with "'intel-hda-duplex' is not a valid device model
  #     name" on qm start).
  #
  # DO NOT add `-display none` here — it would kill the VNC server
  # the Proxmox wrapper sets up. (We hit this exact bug in v0.1.21
  # through v0.1.24; the fix is to use `-vga virtio` for the display
  # and let Proxmox manage the display backend.)
  qm set "$VMID" -args "-audio driver=none -device ich9-intel-hda,id=sound0,bus=pci.0,addr=0x18 -device hda-duplex,id=sound0-codec0,bus=sound0.0,cad=0" >/dev/null

  # ── Performance ────────────────────────────────────────────────────────
  # Disable memory ballooning. The default balloon device causes memory
  # pressure and latency spikes as Proxmox reclaims RAM. With the VM sized
  # for its workload (default 8 GiB) it's strictly better to pin the
  # allocation.
  qm set "$VMID" -balloon 0 >/dev/null

  # Main OS disk (will be filled by the ISO installer)
  qm set "$VMID" -scsi0 "${DISK_STORAGE}:${VMID},iothread=1,discard=on,ssd=1,size=${DISK_SIZE}G" >/dev/null

  # Attach the official Omarchy ISO (the user follows its wizard in the
  # Proxmox console — no cidata / unattended option)
  qm set "$VMID" -ide2 "${STORAGE}:iso/${ISO_FILE},media=cdrom" >/dev/null

  # If MAC_USER=yes, also attach the pre-staged fix script as a second
  # CD-ROM on ide3. Auto-mounts in the installed Omarchy at
  # /run/media/<user>/FIX/fix.sh, so the user can run it with a short
  # local command (no clipboard needed).
  if [[ "$MAC_USER" == "yes" ]]; then
    qm set "$VMID" -ide3 "${STORAGE}:iso/proxmarchy-fix.iso,media=cdrom" >/dev/null
  fi

  # Boot order: ISO first, disk second.
  #   Earlier we tried `order=scsi0;ide2` (disk first, ISO second) on the
  #   theory that the empty disk would fail and the firmware would fall
  #   through to the ISO. OVMF/UEFI doesn't reliably do that — on a
  #   fresh VM with an empty scsi0, the firmware often just gives up
  #   and the VM never tries ide2, so the ISO installer never boots.
  #   Putting the ISO first is what community-scripts does and it's
  #   the only reliable way to get a first-boot into the installer on
  #   OVMF.
  #
  #   SIDE EFFECT: the Omarchy install wizard reboots the VM when
  #   it's done. With `order=ide2;scsi0`, the firmware still tries
  #   ide2 first on the post-install reboot, finds the ISO still
  #   attached, and re-runs the installer. The user has to break
  #   this loop manually after install — the "STOP THE INSTALL LOOP"
  #   one-liner in next-steps does that in a single command. We
  #   don't auto-detach because we have no way to know when install
  #   finishes (the wizard doesn't write a marker we can probe from
  #   the host, and the QEMU guest agent isn't running).
  qm set "$VMID" -boot "order=ide2;scsi0" >/dev/null

  msg_ok "Created Omarchy VM ${BL}(${HN})${CL}"
}

start_vm() {
  if [[ "$START_VM" == "yes" ]]; then
    msg_info "Starting Omarchy VM"
    qm start "$VMID"
    msg_ok "Started Omarchy VM ${BL}${VMID}${CL} — open the Proxmox console to watch the install"
  fi
}

# ----------------------------------------------------------------------------
# 7b. Post-install cleanup (MANUAL — do not call automatically)
#   - This detaches ide2 (Omarchy ISO) and ide3 (mac-fix data ISO)
#     and removes their source ISOs from Proxmox storage.
#   - It is meant to be invoked BY THE USER after the install is done
#     and (if applicable) the mac-fix has been run. It is NOT called
#     from main() — calling it there would hot-unplug the fix CD-ROM
#     from the running VM before the user could ever use it.
#   - Easier alternative: re-run omarchy-vm.sh with the same VMID
#     and pick "destroy + recreate" in the script's whiptail dialog
#     (or let it auto-recreate). That gives you a fully clean state.
# ----------------------------------------------------------------------------
post_install_cleanup() {
  local ISO_DIR ISO_FILE_TO_REMOVE

  # Resolve the same dir-backed path we uploaded to (shared helper)
  ISO_DIR=$(storage_iso_dir "$STORAGE")

  if [[ -z "$ISO_DIR" ]]; then
    msg_info "Skipping ISO cleanup (could not resolve storage path)"
    return 0
  fi
  local ISO_TARGET_DIR="${ISO_DIR}/template/iso"

  # Optional: remove the 6 GB Omarchy ISO too.
  if [[ "$CLEANUP_ISO" == "yes" ]]; then
    if qm set "$VMID" -delete ide2 >/dev/null 2>&1; then
      msg_ok "Detached Omarchy ISO from VM"
    fi
    ISO_FILE_TO_REMOVE="$ISO_FILE"
    if [[ -f "$ISO_TARGET_DIR/$ISO_FILE_TO_REMOVE" ]]; then
      rm -f "$ISO_TARGET_DIR/$ISO_FILE_TO_REMOVE"
      msg_ok "Removed Omarchy ISO from Proxmox storage (${BOLD}~6 GB freed${CL})"
    fi
  else
    msg_info "Keeping ${BL}${ISO_FILE}${CL} in Proxmox storage (CLEANUP_ISO=no)"
  fi

  # Always drop the mac-fix data ISO. It's only ~10 KB, but the end user
  # is done with it after install, so keeping the VM config clean is
  # worth more than the disk space.
  if [[ "$MAC_USER" == "yes" ]]; then
    if qm set "$VMID" -delete ide3 >/dev/null 2>&1; then
      msg_ok "Detached mac-fix data ISO from VM"
    fi
    if [[ -f "$ISO_TARGET_DIR/proxmarchy-fix.iso" ]]; then
      rm -f "$ISO_TARGET_DIR/proxmarchy-fix.iso"
      msg_ok "Removed mac-fix data ISO from Proxmox storage"
    fi
  fi
}

# ----------------------------------------------------------------------------
# 7c. Post-install completion (--complete <vmid>)
#
# This is the user-facing counterpart to the v0.1.28-beta loop-breaker
# one-liner. After the Omarchy wizard finishes and the user is looking
# at Hyprland for the first time, they run:
#
#     bash omarchy-vm.sh --complete <vmid>
#
# This does ALL the host-side cleanup in one shot:
#   1. Gracefully stops the VM (so the install-loop re-runs don't fight
#      with the detach)
#   2. Detaches ide2 (Omarchy ISO) + ide3 (fix CD-ROM). Also tries
#      to detach ide1 (cidata) and remove proxmarchy-cidata.iso for
#      VMs that were created with v0.1.32-beta/v0.1.33-beta (the
#      cidata approach was removed in v0.1.34-beta because it
#      conflicted with the live ISO's cloud-init).
#   3. Switches boot order from `ide2;scsi0` (ISO first) to `scsi0` only
#   4. Removes the source ISOs from Proxmox storage to free disk space
#   5. Starts the VM, which now boots from disk into Hyprland
#
# Idempotent: safe to run multiple times.
# ----------------------------------------------------------------------------
complete_install() {
  local vmid="$1"

  if ! qm status "$vmid" &>/dev/null; then
    msg_error "VM $vmid does not exist (or this isn't a Proxmox host)"
    return 1
  fi

  echo
  msg_info "Proxmarchy post-install completion for VM ${vmid}"
  echo

  # 1. Stop the VM gracefully
  msg_info "Stopping VM ${vmid}"
  if qm stop "$vmid" 2>/dev/null; then
    msg_ok "Stopped"
  else
    msg_info "VM was already stopped"
  fi

  # 2. Detach all install-time CD-ROMs (Omarchy ISO, fix CD-ROM, and
  # the legacy cidata drive from v0.1.32/v0.1.33 in case the user
  # is upgrading from one of those). Each is a no-op if the device
  # isn't there (idempotent).
  for dev in ide1 ide2 ide3; do
    if qm set "$vmid" -delete "$dev" >/dev/null 2>&1; then
      msg_ok "Detached ${dev}"
    fi
  done

  # 3. Switch boot order to disk-only. With all ISOs detached, the
  # firmware will only try scsi0.
  qm set "$vmid" -boot "order=scsi0" >/dev/null && msg_ok "Boot order: scsi0 only"

  # 4. Remove the source ISOs from Proxmox storage to free disk space.
  # Best-effort; missing files are fine.
  local ISO_DIR
  ISO_DIR=$(storage_iso_dir "$STORAGE" 2>/dev/null || true)
  if [[ -n "$ISO_DIR" ]]; then
    local ISO_TARGET_DIR="${ISO_DIR}/template/iso"
    rm -f "${ISO_TARGET_DIR}/omarchy-"*.iso 2>/dev/null && \
      msg_ok "Removed Omarchy ISO from Proxmox storage (~6 GB freed)" || true
    rm -f "${ISO_TARGET_DIR}/proxmarchy-fix.iso" 2>/dev/null && \
      msg_ok "Removed mac-fix data ISO from Proxmox storage" || true
    rm -f "${ISO_TARGET_DIR}/proxmarchy-cidata.iso" 2>/dev/null && \
      msg_ok "Removed cidata ISO from Proxmox storage" || true
  fi

  # 5. Start the VM
  msg_info "Starting VM ${vmid}"
  qm start "$vmid" >/dev/null && msg_ok "Started — VM will boot from disk into Hyprland"

  echo
  echo -e "${GN}${BOLD}✓ Post-install complete.${CL}"
  echo
  echo -e "  ${BOLD}What's next${CL}"
  echo -e "  • Open the Proxmox console for VM ${BOLD}${vmid}${CL} (noVNC)."
  echo -e "  • The VM should land on the SDDM graphical login screen — log in as the"
  echo -e "    user you created during the wizard."
  echo -e "  • If cloud-init was in the Omarchy image, the mac-fix was already applied"
  echo -e "    on first boot — try ${YW}Alt+Space${CL} for the Omarchy menu. You're done."
  echo -e "  • If cloud-init wasn't there, run the fallback one-liner in a terminal"
  echo -e "    inside Hyprland:"
  echo
  echo -e "      ${BL}curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/fix-mac-super-key.sh | bash${CL}"
  echo
}

# ----------------------------------------------------------------------------
# 7d. VM destruction (--destroy <vmid>)
# ----------------------------------------------------------------------------
destroy_vm() {
  local vmid="$1"
  if ! qm status "$vmid" &>/dev/null; then
    msg_error "VM $vmid does not exist"
    return 1
  fi
  msg_info "Stopping VM ${vmid}"
  qm stop "$vmid" 2>/dev/null || true
  msg_info "Destroying VM ${vmid}"
  qm destroy "$vmid" && msg_ok "Destroyed VM ${vmid}"
}

# ----------------------------------------------------------------------------
# 7e. Print top-level help
# ----------------------------------------------------------------------------
print_help() {
  cat <<'EOF'
Proxmarchy — Proxmox-host one-liner installer for Omarchy

Usage:
  omarchy-vm.sh                          Create a new Omarchy VM
  omarchy-vm.sh --complete <vmid>        Post-install completion (one command)
  omarchy-vm.sh --destroy  <vmid>        Destroy the VM
  omarchy-vm.sh --help                   Show this help

Typical flow (one-liner, then this):
  1. bash -c "$(curl -fsSL https://.../omarchy-vm.sh)"
     → walks through the whiptail wizard, creates VM 105, starts it
  2. Walk through the Omarchy ISO installer in the Proxmox console (noVNC)
  3. After the wizard finishes and Hyprland is up:
        bash omarchy-vm.sh --complete 105
     → one command does ALL host-side cleanup (detach ISOs, change
       boot order, remove source ISOs, restart the VM)

If you ever need to start over, --destroy 105 wipes the VM and a fresh
`omarchy-vm.sh` run creates it again.
EOF
}

# ----------------------------------------------------------------------------
# 8. Main
# ----------------------------------------------------------------------------
main() {
  check_root
  arch_check
  pve_check
  require_tools
  ssh_check

  header_info
  echo -e "\n${INFO}${BL}Omarchy VM — community-scripts style${CL}"
  echo -e "${INFO}Source: ${BL}${OMARCHY_REPO}${CL} (live, not pinned)\n"

  start_script
  pick_storage
  pick_disk_storage
  download_omarchy_iso

  # When the end user is on macOS, pre-stage a small data ISO with the
  # Super→Alt fix script. noVNC has no clipboard, so the user can't
  # paste a long one-liner — but they can type a short local path
  # to a file we already placed in the VM.
  if [[ "$MAC_USER" == "yes" ]]; then
    build_mac_fix_iso
  fi

  create_vm
  start_vm

  # NOTE: We deliberately do NOT call post_install_cleanup here. That
  # function detaches ide2 (Omarchy ISO) and ide3 (mac-fix data ISO)
  # and deletes the source ISOs from Proxmox storage — but it would
  # run while the user is still in the live ISO installer, hot-unplug
  # the fix CD-ROM before the user has a chance to use it, and (worse)
  # detach the Omarchy ISO the VM is currently booting from. The
  # user invokes cleanup manually after install — see the "Cleanup
  # after install" section in next-steps below, and the
  # post_install_cleanup function in this script.

  echo
  msg_ok "Omarchy VM ${BGN}${VMID}${CL} (${BL}${HN}${CL}) is ready."
  echo
  echo -e "${INFO}${BOLD}What was attached${CL}"
  echo -e "  • ide2: Omarchy installer ISO (${BL}${ISO_FILE}${CL}) — the VM boots from it"
  if [[ "$MAC_USER" == "yes" ]]; then
    echo -e "  • ide3: proxmarchy-fix data ISO (~10 KB, label FIX) — for the post-install fix"
  fi
  if [[ -n "${ISO_FILE:-}" ]]; then
    echo -e "  • Storage copy of the Omarchy ISO: ${BL}/var/lib/vz/template/iso/${ISO_FILE}${CL}"
  fi
  echo
  echo -e "${INFO}${BOLD}Next steps${CL}"
  echo -e "  • Open the Proxmox console for VM ${BOLD}${VMID}${CL} (noVNC or xterm.js)."
  echo -e "  • The VM boots from the Omarchy ISO — walk through the wizard in the"
  echo -e "    console: keyboard → user → disk → confirm. Installation finishes in"
  echo -e "    a few minutes. ${BOLD}Then the VM reboots, and the boot order (ISO first)"
  echo -e "    makes the installer run again.${CL} That's the section right below."
  echo
  echo -e "  ${YW}${BOLD}⚠  Pick NO encryption in the disk step.${CL} The Omarchy wizard offers"
  echo -e "  ${YW}disk encryption (LUKS). If you accept it, the initramfs will prompt for a"
  echo -e "  ${YW}password at every boot — and there's no way to bypass it from the Proxmox"
  echo -e "  ${YW}host. Worse, typing a long passphrase through noVNC is painful and the"
  echo -e "  ${YW}password is unrecoverable if you forget it. For a personal VM, leave the"
  echo -e "  ${YW}disk unencrypted (ext4 or btrfs) and rely on Proxmox's network isolation"
  echo -e "  ${YW}for at-rest protection.${CL}"
  if [[ "$MAC_USER" == "yes" ]]; then
    echo -e "  ${YW}│${CL}  ${BOLD}macOS noVNC + Super key fix${CL}"
    echo -e "  ${YW}│${CL}  The browser noVNC client on macOS often loses the Super/Cmd key, which"
    echo -e "  ${YW}│${CL}  breaks Omarchy's Super+Space menu, Super+Enter terminal, etc."
    echo -e "  ${YW}│${CL}"
    echo -e "  ${YW}│${CL}  ${BOLD}A small data CD-ROM was attached to the VM with the fix script on it.${CL}"
    echo -e "  ${YW}│${CL}  noVNC has no clipboard, so you can't paste — but the file is already in"
    echo -e "  ${YW}│${CL}  the VM. Open a terminal inside Hyprland (right-click the desktop) and type:"
    echo -e "  ${YW}│${CL}"
    echo -e "  ${YW}│${CL}      ${GN}bash /run/media/omarchy/FIX/fix.sh${CL}"
    echo -e "  ${YW}│${CL}"
    echo -e "  ${YW}│${CL}  (If your username isn't \"omarchy\", replace it: e.g. \`/run/media/jay/FIX/\`."
    echo -e "  ${YW}│${CL}  Or just run \`ls /run/media/\` to find it.)"
    echo -e "  ${YW}│${CL}"
    echo -e "  ${YW}│${CL}  After it runs, ${YW}Alt+Space${CL} opens the Omarchy menu and every other"
    echo -e "  ${YW}│${CL}  Super+X keybind re-maps to Alt+X. Re-run with ${YW}--undo${CL} to revert."
    echo -e "  ${YW}│${CL}"
    echo -e "  ${YW}│${CL}  If for some reason the data CD-ROM is gone, fetch it from GitHub instead:"
    echo -e "  ${YW}│${CL}"
    echo -e "  ${YW}│${CL}      ${BL}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/fix-mac-super-key.sh)\"${CL}"
  fi
  echo -e "  • Inside the VM, keep it current with any of:"
  echo -e "      ${YW}omarchy update${CL}                  (terminal)"
  echo -e "      ${YW}Super + Alt + Space → Update → Omarchy${CL}  (menu)"
  echo -e "  • ${BOLD}That update flow pulls from${CL} ${BL}${OMARCHY_REPO}${CL} ${BOLD}and from the"
  echo -e "    Omarchy pacman mirror — so the in-VM ${YW}omarchy update${CL}${BOLD} IS the way to"
  echo -e "    stay on the latest Omarchy release, not just the latest Arch packages.${CL}"
  echo
  echo -e "  ${YW}${BOLD}⚠  Don't start Hyprland from a TTY.${CL} After the post-install reboot, the"
  echo -e "  ${YW}VM should land on SDDM (the graphical login screen) — log in there. If you"
  echo -e "  ${YW}end up on a black TTY with a text prompt instead, you can still recover, but"
  echo -e "  ${YW}DO NOT type \`Hyprland\` directly: Hyprland will start but XWayland (which it"
  echo -e "  ${YW}spawns for X11 apps) will fail with \`KMS: DRM_IOCTL_MODE_CREATE_DUMB failed:"
  echo -e "  ${YW}Permission denied\` because TTYs don't have a logind-managed seat, so the X"
  echo -e "  ${YW}server can't open the GPU. Instead:"
  echo -e "  ${YW}  1. Make sure SDDM is running: \`sudo systemctl enable --now sddm\`"
  echo -e "  ${YW}  2. Switch to its TTY: \`Ctrl+Alt+F7\` (or F1/F8 if F7 is blank)"
  echo -e "  ${YW}  3. Log in via the SDDM GUI. Hyprland starts automatically on success.${CL}"
  echo
  echo -e "${GN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo -e "${GN}${BOLD}  AFTER THE WIZARD: one command does all the host-side cleanup${CL}"
  echo -e "${GN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo -e "  When the wizard finishes and you're looking at Hyprland for the first time,"
  echo -e "  run this on the Proxmox host (one command, idempotent):"
  echo
  echo -e "      ${GN}${BOLD}bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/omarchy-vm.sh)\" -- --complete ${VMID}${CL}"
  echo
  echo -e "  That: stops the VM, detaches ide2 (Omarchy ISO) + ide3 (fix CD-ROM), switches"
  echo -e "  boot order to disk-only, removes the source ISOs from Proxmox storage"
  echo -e "  (~6 GB freed), and starts the VM. From then on it boots straight into the"
  echo -e "  installed Hyprland."
  echo -e "  (If you saved omarchy-vm.sh locally on the host, \`bash omarchy-vm.sh --complete ${VMID}\`"
  echo -e "  works too. The curl one-liner above always works regardless.)"
  if [[ "$MAC_USER" == "yes" ]]; then
    echo
    echo -e "  ${BOLD}Apply the mac-fix in Hyprland${CL} (one of these — the data CD-ROM is still"
    echo -e "  attached at \`/run/media/${USER:-<your-username>}/FIX/\`):"
    echo
    echo -e "      ${GN}bash /run/media/\$(ls /run/media/ | head -1)/FIX/fix.sh${CL}"
    echo
    echo -e "  Or, in a Hyprland terminal, the GitHub one-liner (longer but always works):"
    echo
    echo -e "      ${BL}curl -fsSL https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/fix-mac-super-key.sh | bash${CL}"
    echo
    echo -e "  After it runs, ${YW}Alt+Space${CL} opens the Omarchy menu. Re-run with \`--undo\` to"
    echo -e "  revert. (See the script header for the undo one-liner.)"
  fi
  echo -e "${GN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${CL}"
  echo
  echo -e "${INFO}${BOLD}Cleanup after install (manual, optional — only when you're done with the VM)${CL}"
  echo -e "  Once you've broken the install loop (above) and run the mac-fix (if applicable),"
  echo -e "  you can free disk space with:"
  if [[ "$MAC_USER" == "yes" ]]; then
    echo -e "      ${YW}qm set ${VMID} -delete ide3${CL}    # detach the mac-fix data ISO"
  fi
  if [[ "$CLEANUP_ISO" == "yes" ]]; then
    echo -e "      ${YW}rm /var/lib/vz/template/iso/${ISO_FILE}${CL}    # ~6 GB freed"
  fi
  if [[ "$MAC_USER" == "yes" ]]; then
    echo -e "      ${YW}rm /var/lib/vz/template/iso/proxmarchy-fix.iso${CL}    # ~10 KB freed"
  fi
  echo -e "  Re-running this script with the same VMID will ${YW}qm destroy${CL} and recreate"
  echo -e "  the VM from scratch, which is equivalent to a full cleanup."
  echo
}

# ----------------------------------------------------------------------------
# 9. Command dispatch
# ----------------------------------------------------------------------------
# Parse the first arg. If it's a subcommand, run it (after a minimal
# env check). Otherwise, fall through to the default create-VM flow.
case "${1:-}" in
  --complete)
    shift
    CVMID="${1:-}"
    if [[ -z "$CVMID" ]]; then
      echo "Usage: omarchy-vm.sh --complete <vmid>" >&2
      exit 1
    fi
    check_root
    pve_check
    require_tools
    complete_install "$CVMID"
    exit $?
    ;;
  --destroy)
    shift
    DVMID="${1:-}"
    if [[ -z "$DVMID" ]]; then
      echo "Usage: omarchy-vm.sh --destroy <vmid>" >&2
      exit 1
    fi
    check_root
    pve_check
    destroy_vm "$DVMID"
    exit $?
    ;;
  --help|-h)
    print_help
    exit 0
    ;;
  "")
    # No args: default flow (create VM)
    main "$@"
    ;;
  *)
    echo "Unknown command: $1" >&2
    echo "Run 'omarchy-vm.sh --help' for usage." >&2
    exit 1
    ;;
esac
