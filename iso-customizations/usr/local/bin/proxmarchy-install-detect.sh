#!/usr/bin/env bash
# proxmarchy-install-detect.sh
#
# Runs in the LIVE ISO environment. Its job is to detect when the
# Omarchy install wizard finishes, and at that moment inject the
# proxmarchy-first-boot service into the just-installed system at
# /mnt. That way, when the VM reboots into the installed Omarchy
# for the first time, the first-boot service is already in place
# and will auto-apply the mac-fix.
#
# Detection strategy:
#   - The Omarchy wizard (archinstall + DHH's install scripts) writes
#     the target filesystem to /mnt and the install is "done" when
#     /mnt/etc/hostname is present AND /mnt/etc/.installing or any
#     archinstall lockfile is gone.
#   - We poll every 2 seconds. If 45 minutes pass with no install
#     detected, we give up cleanly (the user might be exploring the
#     live env, or the install might be doing something exotic).
#
# Idempotency: we write a marker to /var/lib/proxmarchy-installed
# in the live env once we've injected. If the live env is rebooted
# (e.g. user restarts after install), we don't re-inject.

set -u

LOG_TAG="proxmarchy-install-detect"
log()  { printf '%s %s\n' "$(date -Iseconds)" "$*" | systemd-cat -t "$LOG_TAG" 2>/dev/null || echo "$*"; }

LIVE_MARKER="/var/lib/proxmarchy-already-injected"
TARGET="/mnt"
POLL_INTERVAL=2
MAX_WAIT_MIN=45
MAX_POLLS=$(( MAX_WAIT_MIN * 60 / POLL_INTERVAL ))

# Bail early if we already injected (live env was rebooted, etc.)
if [[ -f "$LIVE_MARKER" ]]; then
  log "Already injected (marker at $LIVE_MARKER exists). Exiting."
  exit 0
fi

log "Proxmarchy install-detect watching ${TARGET} for the install to complete..."
log "Will poll every ${POLL_INTERVAL}s for up to ${MAX_WAIT_MIN} minutes."

i=0
while (( i < MAX_POLLS )); do
  # Install is in progress if /mnt is mounted as a target. We use the
  # presence of /mnt/etc/os-release as the "filesystem is being
  # written" signal. Once /mnt/etc/hostname exists and hasn't changed
  # for 10 seconds, we treat the install as done.
  if [[ -f "${TARGET}/etc/hostname" ]]; then
    hn1=$(cat "${TARGET}/etc/hostname" 2>/dev/null || echo "")
    sleep 10
    hn2=$(cat "${TARGET}/etc/hostname" 2>/dev/null || echo "")
    if [[ -n "$hn1" && "$hn1" == "$hn2" ]]; then
      log "Install target stable (hostname='$hn1' for 10s). Injecting first-boot service."
      break
    fi
  fi
  sleep "$POLL_INTERVAL"
  (( i++ ))
done

if (( i >= MAX_POLLS )); then
  log "Timed out after ${MAX_WAIT_MIN} minutes without detecting install completion."
  log "If the install DID complete, the user can run the post-install script manually."
  log "If the install is still in progress, this service will be retried on the next live-env boot."
  exit 0
fi

# ── Inject the first-boot service into /mnt ───────────────────────────
log "Copying /opt/proxmarchy/fix-mac-super-key.sh → ${TARGET}/opt/proxmarchy/"
mkdir -p "${TARGET}/opt/proxmarchy"
if ! cp -f /opt/proxmarchy/fix-mac-super-key.sh "${TARGET}/opt/proxmarchy/fix-mac-super-key.sh"; then
  log "ERROR: failed to copy fix script. Aborting inject."
  exit 1
fi
chmod 0755 "${TARGET}/opt/proxmarchy/fix-mac-super-key.sh"

# The installed-system first-boot service
log "Writing ${TARGET}/etc/systemd/system/proxmarchy-first-boot.service"
mkdir -p "${TARGET}/etc/systemd/system"
cat > "${TARGET}/etc/systemd/system/proxmarchy-first-boot.service" <<'UNIT'
[Unit]
Description=Proxmarchy first-boot: apply mac-fix
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/proxmarchy/installed-first-boot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# The installed-system first-boot script body
log "Writing ${TARGET}/opt/proxmarchy/installed-first-boot.sh"
cat > "${TARGET}/opt/proxmarchy/installed-first-boot.sh" <<'SCRIPT'
#!/usr/bin/env bash
# Proxmarchy first-boot: applies the mac-fix once and signals completion.
# Runs on every boot, but is a no-op after the first successful run
# (the marker file is the idempotency token).

set -u

MARKER="/var/lib/proxmarchy-install-complete"
if [[ -f "$MARKER" ]]; then
  exit 0
fi

# Apply the fix. We don't fail the service if the fix itself fails —
# the user can still run it manually.
if ! /opt/proxmarchy/fix-mac-super-key.sh; then
  echo "proxmarchy: fix-mac-super-key.sh exited non-zero; continuing."
fi

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
exit 0
SCRIPT
chmod 0755 "${TARGET}/opt/proxmarchy/installed-first-boot.sh"

# Enable the service in the installed system
log "Enabling proxmarchy-first-boot.service in the installed system"
if ! arch-chroot "${TARGET}" systemctl enable proxmarchy-first-boot.service >/dev/null 2>&1; then
  log "ERROR: arch-chroot systemctl enable failed. The user may need to enable manually."
  log "  arch-chroot ${TARGET} systemctl enable proxmarchy-first-boot.service"
  exit 1
fi

# Mark live env as already-injected (idempotency across live-env reboots)
mkdir -p "$(dirname "$LIVE_MARKER")"
touch "$LIVE_MARKER"

log "✓ Injected. When the system reboots into the installed Omarchy, the"
log "  proxmarchy-first-boot service will run and apply the mac-fix automatically."
exit 0
