#!/usr/bin/env bash
PROXMARCHY_FIX_VERSION="0.1.30-beta"
# fix-mac-super-key.sh — remap Hyprland's Super modifier so noVNC/SPICE
#                            pass it through on macOS
#
# The problem: on macOS, the browser (noVNC) and/or macOS itself often
# claims the Cmd/Super key for OS-level shortcuts (Spotlight, mission
# control, app launcher) before it reaches the VM. Hyprland's
# keybinds — including the Omarchy menu on Super+Space and the
# terminal on Super+Enter — silently fail.
#
# The fix: swap Alt and Super at the XKB level inside Hyprland. Alt
# (especially Right Alt) is not claimed by macOS, so it passes
# through noVNC cleanly. After the swap, Omarchy's existing
# `bind = SUPER, X, ...` keybinds fire when the user presses the
# physical Alt key.
#
# Optionally, also drop a noVNC "remap hint" into the Hyprland config
# so future users editing the file know what the swap is for.
#
# Usage (inside the Omarchy VM, as the regular user):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jj19/proxmarchy/main/fix-mac-super-key.sh)"
#
#   # To undo:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jj19/proxmarchy/main/fix-mac-super-key.sh)" -- --undo
#
# This script:
#   1. Backs up ~/.config/hypr/hyprland.conf (timestamped).
#   2. Patches the `input { ... }` block to add `kb_options = altwin:swap_alt_win`.
#      (Or removes the swap on --undo.)
#   3. Reloads Hyprland via `hyprctl reload` so the change takes
#      effect without logging out.
#
# After running, `Alt + Space` opens the Omarchy menu, `Alt + Enter`
# opens a terminal, etc. If you also want your physical Mac Cmd key
# to act as Alt in the VM, install Karabiner-Elements on the Mac
# and add a "Simple Modification": left_command → left_alt.

set -eEo pipefail

echo "  Proxmarchy fix-mac-super-key.sh ${PROXMARCHY_FIX_VERSION}"

CONF="${HOME}/.config/hypr/hyprland.conf"
BACKUP_DIR="${HOME}/.config/hypr/backup-super-fix"
UNDO=false

for arg in "$@"; do
  case "$arg" in
    --) continue ;;   # tolerate `bash -c "..." -- --undo` style
    --undo|-u) UNDO=true ;;
    -h|--help)
      cat <<'EOF'
Usage: fix-mac-super-key.sh [--undo]

Patches ~/.config/hypr/hyprland.conf to swap Alt and Super inside
Hyprland, so noVNC on macOS passes the modifier through cleanly.

With no flag: adds the swap (creates a timestamped backup first).
With --undo:   removes the swap and restores the most recent backup.

After the forward patch:
  Alt + Space   →  Omarchy menu
  Alt + Enter   →  terminal
  Alt + Alt + Space   →  Update → Omarchy
  (every other Super+X keybind also re-maps to Alt+X)

To make your physical Mac Cmd key act as Alt in the VM, install
Karabiner-Elements on the Mac and add a "Simple Modification":
left_command → left_alt
EOF
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
note() { printf '  %s\n' "$*"; }
ok()   { printf '  ✔  %s\n' "$*"; }
warn() { printf '  ⚠  %s\n' "$*" >&2; }
die()  { printf '  ✖  %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
command -v hyprctl >/dev/null 2>&1 || die "hyprctl not found — is Hyprland running and is this the Omarchy user session?"

mkdir -p "$BACKUP_DIR"

if [[ ! -f "$CONF" ]]; then
  # No config yet. Most common cause: the user is on a fresh Omarchy
  # install and hasn't logged into the Hyprland session yet (e.g. they're
  # in a TTY or a terminal they opened before Hyprland started). We
  # don't fail here — we create a minimal config with the swap already
  # in place, and tell the user to log into Hyprland for it to take
  # effect. When Hyprland starts for the first time, it will see this
  # config and apply the swap. (If Omarchy later writes a fuller config
  # via its post-install hook, the swap line will already be in the
  # `input { }` block by then — re-running this script with --undo and
  # then again without will reconcile if needed.)
  note "$CONF does not exist yet — creating a minimal one with the altwin swap."
  mkdir -p "$(dirname "$CONF")"
  cat > "$CONF" <<'EOF'
# Minimal Hyprland config — created by proxmarchy/fix-mac-super-key.sh
# because no config existed when the fix was run. Omarchy's installer
# may overwrite or merge with this on first Hyprland start; the
# kb_options line below is idempotent and safe to keep.

input {
    kb_layout = us
    kb_options = altwin:swap_alt_win
}
EOF
  ok "Created $CONF with kb_options = altwin:swap_alt_win"
  note "Log into the Hyprland session (or run 'Hyprland' from a TTY) for the swap to take effect."
  note "After that, Alt+Space will open the Omarchy menu. Re-run this script later to"
  note "make sure the swap is in the real config Omarchy wrote."
  exit 0
fi

# ----------------------------------------------------------------------------
# --undo: restore the most recent backup, then strip any stray swap line
# ----------------------------------------------------------------------------
if $UNDO; then
  LATEST_BAK="$(ls -1t "$BACKUP_DIR"/hyprland.conf.bak.* 2>/dev/null | head -n1 || true)"
  if [[ -z "$LATEST_BAK" ]]; then
    die "No backup found in $BACKUP_DIR — cannot undo."
  fi
  note "Restoring $LATEST_BAK → $CONF"
  cp -f "$LATEST_BAK" "$CONF"
  ok "Restored $CONF from backup"

  # Also strip any remaining swap line, just in case
  TMP="$(mktemp)"
  grep -v "kb_options = altwin:swap_alt_win" "$CONF" > "$TMP" || true
  if ! cmp -s "$TMP" "$CONF"; then
    cp -f "$TMP" "$CONF"
    ok "Stripped any remaining altwin:swap_alt_win line"
  fi
  rm -f "$TMP"

  note "Reloading Hyprland…"
  if hyprctl reload >/dev/null 2>&1; then
    ok "Hyprland reloaded. Super keybinds are back to the physical Super key."
  else
    warn "hyprctl reload failed — try logging out and back in, or running 'Hyprland' from a TTY."
  fi
  exit 0
fi

# ----------------------------------------------------------------------------
# Forward path: back up, then patch
# ----------------------------------------------------------------------------

# Bail early if the swap is already in place
if grep -q "kb_options = altwin:swap_alt_win" "$CONF"; then
  ok "kb_options = altwin:swap_alt_win is already in $CONF — nothing to do."
  note "If the keybinds still don't work, run this script with --undo and try again, or check:"
  note "  cat ~/.config/hypr/hyprland.conf | grep -A4 'input {'"
  exit 0
fi

# Timestamped backup
STAMP="$(date +%Y%m%d-%H%M%S)"
BAK="${BACKUP_DIR}/hyprland.conf.bak.${STAMP}"
cp -p "$CONF" "$BAK"
ok "Backed up $CONF → $BAK"

# Locate the input { ... } block. If it exists, insert/replace the
# kb_options line inside it. Otherwise append a new input { } block.
if grep -q "^[[:space:]]*input[[:space:]]*{" "$CONF"; then
  TMP="$(mktemp)"
  python3 - "$CONF" > "$TMP" <<'PYEOF'
import re, sys
p = sys.argv[1]
with open(p) as f:
    text = f.read()

# Find the first "input { ... }" block (balanced braces; allow nested)
def find_block(text, start):
    i = start
    depth = 0
    in_str = None
    while i < len(text):
        c = text[i]
        if in_str:
            if c == '\\': i += 2; continue
            if c == in_str: in_str = None
        else:
            if c in ('"', "'"): in_str = c
            elif c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0: return start, i
        i += 1
    return -1, -1

m = re.search(r'^\s*input\s*\{', text, re.M)
if not m:
    # Shouldn't happen — caller already checked
    sys.exit(0)
start, end = find_block(text, m.start())
body = text[start:end+1]

if "altwin:swap_alt_win" in body:
    # already present, no-op
    print(text, end='')
else:
    if re.search(r'^\s*kb_options\s*=', body, re.M):
        # Replace existing kb_options line
        new_body = re.sub(
            r'^(\s*)kb_options\s*=.*$',
            r'\1kb_options = altwin:swap_alt_win',
            body,
            count=1,
            flags=re.M,
        )
    else:
        # Insert a kb_options line right after the opening "input {"
        new_body = re.sub(
            r'(^\s*input\s*\{\s*$)',
            r'\1\n    kb_options = altwin:swap_alt_win',
            body,
            count=1,
            flags=re.M,
        )
    new_text = text[:start] + new_body + text[end+1:]
    print(new_text, end='')
PYEOF
  if cmp -s "$TMP" "$CONF"; then
    die "patcher made no changes — please file an issue at https://github.com/jj19/proxmarchy/issues"
  fi
  cp -f "$TMP" "$CONF"
  rm -f "$TMP"
  ok "Patched existing input { ... } block with kb_options = altwin:swap_alt_win"
else
  # No input block yet — append one
  cat >> "$CONF" <<'EOF'

# Added by proxmarchy/fix-mac-super-key.sh — swap Alt and Super so
# noVNC on macOS passes the modifier through. Press the physical Alt
# key to fire Omarchy's Super+X keybinds. To revert, delete this block
# or re-run with --undo.
input {
    kb_layout = us
    kb_options = altwin:swap_alt_win
}
EOF
  ok "Appended a new input { ... } block with kb_options = altwin:swap_alt_win"
fi

# Reload Hyprland
note "Reloading Hyprland…"
if hyprctl reload >/dev/null 2>&1; then
  ok "Hyprland reloaded. Try Alt+Space for the Omarchy menu."
else
  warn "hyprctl reload failed (often OK if Hyprland isn't running yet). Log out and back in, or run 'Hyprland' from a TTY."
fi

echo
cat <<'EOF'
  💡  Next steps
  • Try Alt + Space — the Omarchy menu (walker) should open.
  • Try Alt + Enter — a terminal should open.
  • All other Super+X keybinds (terminal, screenshots, etc.) also
    re-bind to Alt+X. The Omarchy menu's "Show keybinds" cheat sheet
    (Super+K → Alt+K) lists them all.
  • Optional: install Karabiner-Elements on your Mac and add a
    "Simple Modification": left_command → left_alt. That makes
    your physical Mac Cmd key behave as Alt in the VM, so your
    muscle memory works.

  To undo later:
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/jj19/proxmarchy/main/fix-mac-super-key.sh)" -- --undo
EOF
