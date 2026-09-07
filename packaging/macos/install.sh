#!/bin/bash
#
# Secarma agent — macOS unattended installer.
#
# Downloads the signed .pkg, writes the config with the org-token from the
# environment, and installs it. Designed for automated/MDM/script deployment:
#
#   sudo SECARMA_ORG_TOKEN=sec_xxxxxxxx ./install.sh
#   curl -fsSL https://downloads.secarma.com/agent/install.sh | sudo SECARMA_ORG_TOKEN=sec_xxx bash
#
# Required env:
#   SECARMA_ORG_TOKEN   the account org-token (starts "sec_"). Never logged.
#
# Optional env:
#   SECARMA_SERVER_URL  platform base URL           (default: https://mon-api.secarma.com)
#   SECARMA_VERSION     pin a version, e.g. 0.1.0   (default: latest, from VERSION.md)
#   SECARMA_PKG_URL     fully override the download  (default: derived from the version)
#   SECARMA_PKG_SHA256  expected sha256 of the .pkg  (verified when set)
#   SECARMA_SKIP_NOTARIZATION_CHECK=1  skip the Gatekeeper check (dev / unsigned builds)
#
set -euo pipefail

SERVER_URL="${SECARMA_SERVER_URL:-https://mon-api.secarma.com}"
REPO="Secarma-act/secarma-agent"
VERSION_URL="https://raw.githubusercontent.com/${REPO}/refs/heads/main/VERSION.md"

SUPPORT_DIR="/Library/Application Support/Secarma"
CONFIG_FILE="$SUPPORT_DIR/config.json"
LOG_DIR="/Library/Logs/Secarma"
PLIST="/Library/LaunchDaemons/com.secarma.agent.plist"

log()  { printf '[secarma-install] %s\n' "$*"; }
die()  { printf '[secarma-install] ERROR: %s\n' "$*" >&2; exit 1; }

# --- Preconditions --------------------------------------------------------------
[ "$(id -u)" -eq 0 ]                || die "must run as root (use sudo)."
[ "$(uname -s)" = "Darwin" ]        || die "this installer is for macOS only."
[ -n "${SECARMA_ORG_TOKEN:-}" ]     || die "SECARMA_ORG_TOKEN is required."
case "$SECARMA_ORG_TOKEN" in
  sec_*) ;;
  *) die "SECARMA_ORG_TOKEN does not look like an org-token (expected it to start with 'sec_')." ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
pkg="$tmp/secarma-agent.pkg"

# --- Resolve version + download URL ---------------------------------------------
version="${SECARMA_VERSION:-}"
if [ -z "$version" ]; then
  log "resolving latest version…"
  version="$(curl -fsSL --retry 3 --retry-delay 2 "$VERSION_URL" 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" \
    || true
  [ -n "$version" ] || die "could not determine the latest version from $VERSION_URL"
fi
log "version: $version"

pkg_url="${SECARMA_PKG_URL:-https://github.com/${REPO}/releases/download/v${version}/secarma-agent-${version}.pkg}"

# --- Download -------------------------------------------------------------------
log "downloading $pkg_url"
curl -fsSL --retry 3 --retry-delay 2 "$pkg_url" -o "$pkg" \
  || die "download failed from $pkg_url"

# --- Integrity / authenticity ---------------------------------------------------
if [ -n "${SECARMA_PKG_SHA256:-}" ]; then
  actual="$(shasum -a 256 "$pkg" | awk '{print $1}')"
  [ "$actual" = "$SECARMA_PKG_SHA256" ] || die "checksum mismatch (got $actual)."
  log "checksum verified."
fi

if [ "${SECARMA_SKIP_NOTARIZATION_CHECK:-0}" != "1" ]; then
  spctl -a -vv -t install "$pkg" >/dev/null 2>&1 \
    || die "package failed the Gatekeeper/notarization check. Set SECARMA_SKIP_NOTARIZATION_CHECK=1 for a dev build."
  log "notarization verified."
fi

# --- Write config (before install, so the daemon has it on first launch) --------
log "writing config to $CONFIG_FILE"
mkdir -p "$SUPPORT_DIR" "$LOG_DIR"
umask 077
cat > "$CONFIG_FILE" <<EOF
{
  "server_url": "$SERVER_URL",
  "org_token": "$SECARMA_ORG_TOKEN",
  "credentials_file": "$SUPPORT_DIR/agent-credentials.json",
  "buffer": { "dir": "$SUPPORT_DIR/buffer" },
  "log": { "file": "$LOG_DIR/secarma-agent.log" }
}
EOF
chown root:wheel "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# --- Install (lays down the binary + LaunchDaemon; postinstall loads it) ---------
log "installing package…"
installer -pkg "$pkg" -target / >/dev/null || die "installer failed."

# --- Verify ---------------------------------------------------------------------
if launchctl print system/com.secarma.agent >/dev/null 2>&1 \
   || launchctl list | grep -q com.secarma.agent; then
  log "installed — the agent is running and will enrol on first collection."
else
  log "installed, but the LaunchDaemon isn't listed yet. Check $LOG_DIR and: sudo launchctl load -w $PLIST"
fi
