#!/usr/bin/env bash
# force-fresh.sh — fetch the absolute-latest omarchy-vm.sh from the
#                   proxmarchy repo, sidestepping every HTTP cache.
#
# When in doubt whether your `curl` is hitting a stale CDN or API
# cache (it has been observed during this rapid release cycle), this
# script clones the repo over the Git protocol, which doesn't go
# through any HTTP cache layer at all. The result is the absolute
# freshest content of omarchy-vm.sh on main, every time.
#
# Usage (on the Proxmox host):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jj19/proxmarchy/main/force-fresh.sh)"
#
# or, if you don't even trust raw.githubusercontent.com:
#   bash <(git clone --depth 1 https://github.com/jj19/proxmarchy /tmp/proxmarchy && bash /tmp/proxmarchy/force-fresh.sh)
#
# Either way, this script prints the first ~30 lines of the live
# script (including the version banner) and saves it to
# /tmp/omarchy-vm.sh, ready to inspect or run.

set -eEo pipefail

# Try a sequence of fallbacks, in order of how reliable they are
# against CDN / API caching. The first one that succeeds wins.
TMP_DIR="$(mktemp -d)"
TARGET="/tmp/omarchy-vm.sh"

echo "Fetching the latest omarchy-vm.sh from jj19/proxmarchy@main..."
echo

# 1. The gold standard: shallow git clone (the smart git protocol, not
#    HTTP caching). Always gets the absolute latest from the Git pack
#    server, no CDN or API in the way.
if command -v git >/dev/null 2>&1; then
  if git clone --depth 1 --filter=blob:none --sparse https://github.com/jj19/proxmarchy.git "$TMP_DIR/repo" 2>/dev/null; then
    if git -C "$TMP_DIR/repo" sparse-checkout set omarchy-vm.sh 2>/dev/null; then
      cp "$TMP_DIR/repo/omarchy-vm.sh" "$TARGET"
      echo "  [via git clone + sparse-checkout]  $TARGET"
    else
      # Fallback: full shallow clone + extract the one file
      rm -rf "$TMP_DIR/repo"
      git clone --depth 1 https://github.com/jj19/proxmarchy.git "$TMP_DIR/repo" 2>/dev/null
      cp "$TMP_DIR/repo/omarchy-vm.sh" "$TARGET"
      echo "  [via git clone]                       $TARGET"
    fi
    SIZE=$(wc -c < "$TARGET")
    SHA=$(git -C "$TMP_DIR/repo" rev-parse HEAD)
    echo "  commit:    $SHA"
    echo "  size:      $SIZE bytes"
    echo "  version banner:"
    grep -m 1 'Proxmarchy omarchy-vm.sh' "$TARGET" | sed 's/^/    /'
    echo
    rm -rf "$TMP_DIR"
    echo "Saved to $TARGET — inspect with 'less $TARGET' or just run it:"
    echo "  bash $TARGET"
    exit 0
  fi
fi

# 2. API fallback (in case git isn't installed on the host — unusual
#    but possible on a stripped-down Proxmox image).
if command -v python3 >/dev/null 2>&1; then
  echo "  (git not available, trying GitHub API)"
  if curl -fsSL "https://api.github.com/repos/jj19/proxmarchy/contents/omarchy-vm.sh?ref=main" -o "$TMP_DIR/api.json" 2>/dev/null; then
    if python3 -c 'import json,base64,sys; sys.stdout.write(base64.b64decode(json.load(sys.stdin)["content"]).decode())' < "$TMP_DIR/api.json" > "$TARGET" 2>/dev/null; then
      SIZE=$(wc -c < "$TARGET")
      SHA=$(python3 -c "import json; print(json.load(open('$TMP_DIR/api.json'))['sha'])" 2>/dev/null || echo unknown)
      echo "  [via GitHub API]    $TARGET"
      echo "  sha:        $SHA"
      echo "  size:       $SIZE bytes"
      echo "  version banner:"
      grep -m 1 'Proxmarchy omarchy-vm.sh' "$TARGET" | sed 's/^/    /'
      echo
      rm -rf "$TMP_DIR"
      echo "Saved to $TARGET — inspect with 'less $TARGET' or just run it:"
      echo "  bash $TARGET"
      exit 0
    fi
  fi
fi

# 3. Last-ditch: raw CDN with every possible cache-buster. Will
#    fail if even this is cached, but worth trying.
echo "  (no git, no python3 — falling back to raw CDN with cache-busters)"
if curl -fsSL "https://raw.githubusercontent.com/jj19/proxmarchy/main/omarchy-vm.sh?nocache=$(date +%s%N)-$RANDOM" -o "$TARGET" 2>/dev/null; then
  SIZE=$(wc -c < "$TARGET")
  echo "  [via raw CDN cache-buster]   $TARGET"
  echo "  size:       $SIZE bytes"
  echo "  version banner:"
  grep -m 1 'Proxmarchy omarchy-vm.sh' "$TARGET" | sed 's/^/    /'
  echo
  rm -rf "$TMP_DIR"
  echo "Saved to $TARGET — inspect with 'less $TARGET' or just run it:"
  echo "  bash $TARGET"
  exit 0
fi

echo "ERROR: all fetch strategies failed. Check network access to github.com."
rm -rf "$TMP_DIR"
exit 1
