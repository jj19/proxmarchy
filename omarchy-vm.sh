#!/usr/bin/env bash
# omarchy-vm.sh — Proxmox helper-script style installer for Omarchy
#
# Pulls the LATEST official Omarchy ISO from omarchy.org at run time, builds
# a `cidata` (cloud-init NoCloud) drive for fully unattended install using
# the official `user_configuration.json` / `user_credentials.json` schema
# documented at https://omarchy.org/manual/unattended-installs/, and
# creates a UEFI / Q35 / virtio-gpu Proxmox VM that boots the official
# Omarchy ISO.
#
# Once the wizard (or cidata) finishes, the resulting VM is a full Omarchy
# install with `~/.local/share/omarchy` cloned from
# https://github.com/basecamp/omarchy — so the standard
#   omarchy update
# command (or Super+Alt+Space → Update → Omarchy) keeps it current.
#
# This script is intended to be run on the Proxmox host shell.
#
# Usage (host shell):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/vm/omarchy-vm.sh)"
#
# License: MIT
set -eEo pipefail

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
   ___  __  __                             __  __
  / _ \/ / / /  ___ __________  ___  ___  / /_/ /
 / // / /_/ / / _ `/ __/ __/ _ \/ _ \/ _ \/ __/_/
/____/\____/_/\_,_/_/  \__/\___/_//_/_//_/\__/  
                                                  
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
  local PVE_VER
  PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  if [[ "$PVE_VER" =~ ^8\.([0-9]+)$ ]] || [[ "$PVE_VER" =~ ^9\.[0-2]$ ]]; then
    return 0
  fi
  msg_error "Proxmox VE ${PVE_VER} not supported (need 8.x or 9.0–9.2)."
  exit 1
}

require_tools() {
  for t in qm pvesm whiptail curl openssl genisoimage awk sed numfmt du; do
    command -v "$t" >/dev/null 2>&1 || {
      msg_error "Missing required tool: $t (apt install genisoimage xorriso)"
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
  UNATTENDED="yes"
  CLEANUP_ISO="yes"   # remove the 6 GB Omarchy ISO from Proxmox storage after install
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
  echo -e "${DEFAULT}${BOLD}${DGN}Install: ${BGN}unattended (cidata) — full Omarchy${CL}"
  echo -e "${GATEWAY:-${DEFAULT}}${BOLD}${DGN}Start VM when done: ${BGN}yes${CL}"
  echo -e "${DEFAULT}${BOLD}${DGN}Remove Omarchy ISO from storage after install: ${BGN}yes${CL}  ${YW}(saves ~6 GB)${CL}"
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

  # Unattended install?
  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "INSTALL MODE" \
      --yesno "Use unattended install (cidata, full Omarchy)?" --no-button "Interactive wizard" 10 58; then
    UNATTENDED="yes"
    echo -e "${DEFAULT}${BOLD}${DGN}Install: ${BGN}unattended (cidata)${CL}"
  else
    UNATTENDED="no"
    echo -e "${DEFAULT}${BOLD}${DGN}Install: ${BGN}interactive ISO wizard${CL}"
  fi

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
        --title "Storage Pools" --radiolist \
        "Which storage pool for ${HN} ISO + disk? (Space to select)\nPick a dir-backed one — script copies the ISO into it directly." \
        16 $((MSG_MAX_LENGTH + 23)) 6 \
        "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit_script
    done
  fi
  msg_ok "Using storage: ${BL}${STORAGE}${CL}"
}

# ----------------------------------------------------------------------------
# 4b. Upload an ISO into a Proxmox storage pool
#
# Strategy:
#   1. Read /etc/pve/storage.cfg to find a writable `path` for this storage.
#   2. If found, copy the file directly into `<path>/template/iso/`.
#   3. Otherwise (LVM-thin / ZFS / Ceph / etc.) the script refuses with a
#      clear message: those storage types don't expose a writable ISO dir,
#      and uploading via the PVE API needs a real user ticket. The user
#      should pick a dir-backed storage (e.g. `local`) for the ISO + cidata.
# ----------------------------------------------------------------------------
upload_iso_to_storage() {
  local SRC_FILE="$1"      # path on disk
  local DEST_NAME="$2"     # filename inside Proxmox storage
  local STORAGE="$3"       # Proxmox storage ID

  local ISO_DIR
  ISO_DIR=$(awk -v st="$STORAGE" '
    BEGIN { in_storage=0 }
    {
      # Storage definition lines look like: "dir: local" or "lvmthin: local-lvm"
      # The first field is the storage TYPE (with trailing colon), the second
      # field is the storage ID. Match the type pattern to detect a new
      # storage block, then read its ID from $2.
      if ($1 ~ /^[a-zA-Z0-9_.-]+:$/) {
        current = $2
        in_storage = (current == st)
        next
      }
      if (in_storage && $1 == "path") {
        print $2
        exit
      }
    }
  ' /etc/pve/storage.cfg 2>/dev/null || true)

  if [[ -n "$ISO_DIR" ]]; then
    mkdir -p "${ISO_DIR}/template/iso"
    cp -f "$SRC_FILE" "${ISO_DIR}/template/iso/${DEST_NAME}"
    msg_ok "Stored ISO in ${BL}${ISO_DIR}/template/iso/${DEST_NAME}${CL}"
    return 0
  fi

  msg_error "Storage '${STORAGE}' has no local path (LVM-thin / ZFS / Ceph / etc.)."
  msg_error "Pick a dir-backed storage for the ISOs (typical: 'local'), or upload"
  msg_error "  ${DEST_NAME}"
  msg_error "to the Proxmox UI (Datacenter → Node → Storage → 'local' → ISO Images → Upload)"
  msg_error "and re-run this script."
  exit 1
}

# ----------------------------------------------------------------------------
# 5. Pull the latest Omarchy ISO (always fresh)
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

  msg_info "Downloading ${ISO_FILE}"
  if ! curl -f#SL -o "$ISO_FILE" "$ISO_URL"; then
    msg_error "ISO download failed: $ISO_URL"
    exit 1
  fi
  echo -en "\e[1A\e[0K"
  msg_ok "Downloaded ${BL}${ISO_FILE}${CL} (${BOLD}$(du -h "$ISO_FILE" | awk '{print $1}')${CL})"
}

# ----------------------------------------------------------------------------
# 6. Build a `cidata` (cloud-init NoCloud) drive for unattended install
#    Per https://omarchy.org/manual/unattended-installs/
# ----------------------------------------------------------------------------
build_cidata() {
  local CIDATA_DIR
  CIDATA_DIR="$(mktemp -d)"

  # Username
  local USERNAME
  USERNAME=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "OMARCHY USER" \
    --inputbox "Create a Linux user (sudoer, omarchy owner)" 8 58 "omarchy" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit_script
  [[ -z "$USERNAME" ]] && USERNAME="omarchy"

  # Password (and confirmation)
  local PASSWORD PASSWORD2
  while true; do
    PASSWORD=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "OMARCHY PASSWORD" \
      --passwordbox "Password for '$USERNAME' (used for sudo / login)" 9 58 \
      --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit_script
    PASSWORD2=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "OMARCHY PASSWORD" \
      --passwordbox "Confirm password" 9 58 \
      --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit_script
    [[ -n "$PASSWORD" && "$PASSWORD" == "$PASSWORD2" ]] && break
    whiptail --msgbox "Passwords don't match (or empty). Try again." 8 58
  done

  # Hostname (default already $HN from earlier, but allow override)
  HN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "HOSTNAME" \
    --inputbox "VM / system hostname" 8 58 "$HN" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit_script
  [[ -z "$HN" ]] && HN="omarchy"

  # Timezone
  local TIMEZONE
  TIMEZONE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "TIMEZONE" \
    --inputbox "Linux timezone (e.g. America/Los_Angeles, Europe/Berlin)" 8 58 \
    "${TIMEZONE:-$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)}" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit_script
  [[ -z "$TIMEZONE" ]] && TIMEZONE="UTC"

  # Keyboard layout
  local KEYBOARD
  KEYBOARD=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "KEYBOARD" \
    --inputbox "Console keymap (e.g. us, uk, de, fr, es)" 8 58 "us" \
    --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit_script
  [[ -z "$KEYBOARD" ]] && KEYBOARD="us"

  # Optional Git name/email for Omarchy's default git config
  local FULL_NAME EMAIL
  if whiptail --yesno "Configure git author (full name + email) now?" 10 58; then
    FULL_NAME=$(whiptail --inputbox "Git full name" 8 58 "$FULL_NAME" \
      --cancel-button Skip 3>&1 1>&2 2>&3) || FULL_NAME=""
    EMAIL=$(whiptail --inputbox "Git email" 8 58 "$EMAIL" \
      --cancel-button Skip 3>&1 1>&2 2>&3) || EMAIL=""
  fi

  # Optional SSH public key (so the VM is SSH-ready right after install)
  local AUTHORIZED_KEYS_CONTENT=""
  if whiptail --yesno "Drop in an SSH public key for '$USERNAME' now?\n(Yes = paste it; No = set it up later inside the VM.)" 12 62; then
    AUTHORIZED_KEYS_CONTENT=$(whiptail --inputbox \
      "Paste one ssh-ed25519 / ssh-rsa public key (single line)" 10 78 \
      --cancel-button Skip 3>&1 1>&2 2>&3) || AUTHORIZED_KEYS_CONTENT=""
  fi

  # ---- Write cidata files (verbatim schema from omarchy.org/manual) ----
  local PW_HASH
  PW_HASH=$(openssl passwd -6 "$PASSWORD")

  cat > "$CIDATA_DIR/user_configuration.json" <<EOF
{
  "disk": "/dev/vda",
  "hostname": "$HN",
  "timezone": "$TIMEZONE",
  "keyboard": "$KEYBOARD"
}
EOF

  cat > "$CIDATA_DIR/user_credentials.json" <<EOF
{
  "username": "$USERNAME",
  "password_hash": "$PW_HASH"
}
EOF

  if [[ -n "$FULL_NAME" ]]; then echo "$FULL_NAME" > "$CIDATA_DIR/user_full_name.txt"; fi
  if [[ -n "$EMAIL" ]]; then echo "$EMAIL" > "$CIDATA_DIR/user_email_address.txt"; fi
  if [[ -n "$AUTHORIZED_KEYS_CONTENT" ]]; then
    printf '%s\n' "$AUTHORIZED_KEYS_CONTENT" > "$CIDATA_DIR/authorized_keys"
  fi

  CIDATA_ISO="cidata.iso"
  msg_info "Building cidata drive (label=cidata)"
  # Label MUST be "cidata" for Omarchy's NoCloud auto-detect
  (cd "$CIDATA_DIR" && genisoimage -output "../$CIDATA_ISO" -volid cidata -joliet -rock ./* >/dev/null)
  msg_ok "Built cidata drive: ${BL}${CIDATA_ISO}${CL}"
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
  qm set "$VMID" -efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0" >/dev/null

  # VirtIO-GPU is the recommended Wayland display for Hyprland on Proxmox
  qm set "$VMID" -vga virtio,memory=64 >/dev/null
  # Serial console (handy for Proxmox xterm.js)
  qm set "$VMID" -serial0 socket >/dev/null

  # Main OS disk (will be filled by the ISO installer)
  qm set "$VMID" -scsi0 "${STORAGE}:${VMID},iothread=1,discard=on,ssd=1,size=${DISK_SIZE}G" >/dev/null

  # Attach the official Omarchy ISO
  qm set "$VMID" -ide2 "${STORAGE}:iso/${ISO_FILE},media=cdrom" >/dev/null
  # Attach the cidata drive (unattended install) if we built one
  if [[ -n "${CIDATA_ISO:-}" && -f "$TEMP_DIR/$CIDATA_ISO" ]]; then
    qm set "$VMID" -ide3 "${STORAGE}:iso/${CIDATA_ISO},media=cdrom" >/dev/null
  fi

  # Boot order: disk first so the empty disk falls through to the ISO on the
  # first boot. After install, the VM boots straight from disk.
  qm set "$VMID" -boot "order=scsi0;ide2" >/dev/null

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
# 7b. Post-install cleanup
#   - Always drop the cidata ISO from Proxmox storage (one-shot, only used on
#     the first boot; detaching it from the VM is also fine but we do both).
#   - If the user opted in, also drop the Omarchy ISO to reclaim ~6 GB.
#   - The TEMP_DIR was already cleaned up by the EXIT trap, so we only deal
#     with the copies that ended up in the Proxmox storage pool.
# ----------------------------------------------------------------------------
post_install_cleanup() {
  local ISO_DIR ISO_FILE_TO_REMOVE

  # Resolve the same dir-backed path we uploaded to
  ISO_DIR=$(awk -v st="$STORAGE" '
    BEGIN { in_storage=0 }
    {
      if ($1 ~ /^[a-zA-Z0-9_.-]+:$/) {
        current = $2
        in_storage = (current == st)
        next
      }
      if (in_storage && $1 == "path") {
        print $2
        exit
      }
    }
  ' /etc/pve/storage.cfg 2>/dev/null || true)

  if [[ -z "$ISO_DIR" ]]; then
    msg_info "Skipping ISO cleanup (could not resolve storage path)"
    return 0
  fi
  local ISO_TARGET_DIR="${ISO_DIR}/template/iso"

  # Always: remove the cidata drive from the VM and from storage.
  if [[ -n "${CIDATA_ISO:-}" ]]; then
    if qm set "$VMID" -delete ide3 >/dev/null 2>&1; then
      msg_ok "Detached cidata drive from VM"
    fi
    if [[ -f "$ISO_TARGET_DIR/$CIDATA_ISO" ]]; then
      rm -f "$ISO_TARGET_DIR/$CIDATA_ISO"
      msg_ok "Removed cidata ISO from Proxmox storage"
    fi
  fi

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
  download_omarchy_iso

  if [[ "$UNATTENDED" == "yes" ]]; then
    build_cidata
  else
    CIDATA_ISO=""
    msg_info "Skipping cidata — you'll be walked through the ISO wizard in the VM console"
  fi

  # Push the ISOs into the Proxmox storage so qm can attach them
  upload_iso_to_storage "$ISO_FILE" "$ISO_FILE" "$STORAGE"
  if [[ -n "${CIDATA_ISO:-}" && -f "$TEMP_DIR/$CIDATA_ISO" ]]; then
    upload_iso_to_storage "$TEMP_DIR/$CIDATA_ISO" "$CIDATA_ISO" "$STORAGE"
  fi

  create_vm
  start_vm
  post_install_cleanup

  echo
  msg_ok "Omarchy VM ${BGN}${VMID}${CL} (${BL}${HN}${CL}) is ready."
  echo
  if [[ "$CLEANUP_ISO" == "yes" ]]; then
    echo -e "${INFO}${BOLD}Cleanup${CL}"
    echo -e "  • cidata ISO: ${YW}detached from VM and removed from Proxmox storage${CL}"
    echo -e "  • Omarchy ISO: ${YW}detached from VM and removed from Proxmox storage (~6 GB freed)${CL}"
    echo -e "  • The downloaded copies in the script's TEMP_DIR were already wiped on exit"
    echo
  else
    echo -e "${INFO}${BOLD}Cleanup${CL}"
    echo -e "  • cidata ISO: ${YW}detached from VM and removed from Proxmox storage${CL}"
    echo -e "  • Omarchy ISO: ${YW}KEPT in Proxmox storage (re-attach later if you want to re-install)${CL}"
    echo
  fi
  echo -e "${INFO}${BOLD}Next steps${CL}"
  echo -e "  • Open the Proxmox console for VM ${BOLD}${VMID}${CL} (noVNC or xterm.js)."
  if [[ "$UNATTENDED" == "yes" ]]; then
    echo -e "  • The first boot reads cidata and installs silently; you'll land on the"
    echo -e "    Hyprland desktop when it's done (~5–10 min on fast storage)."
  else
    echo -e "  • Walk through the ISO wizard: keyboard → user → disk → confirm."
  fi
  echo -e "  • Inside the VM, keep it current with any of:"
  echo -e "      ${YW}omarchy update${CL}                  (terminal)"
  echo -e "      ${YW}Super + Alt + Space → Update → Omarchy${CL}  (menu)"
  echo -e "  • ${BOLD}That update flow pulls from${CL} ${BL}${OMARCHY_REPO}${CL} ${BOLD}and from the"
  echo -e "    Omarchy pacman mirror — so the in-VM `omarchy update` IS the way to"
  echo -e "    stay on the latest Omarchy release, not just the latest Arch packages.${CL}"
  echo
}

main "$@"
