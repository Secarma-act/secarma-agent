#!/bin/bash
#
# Secarma agent — Linux unattended installer (systemd).
#
# Downloads the agent binary, writes the config with the org-token from the
# environment, installs a systemd service, and starts it. For automated/MDM/script
# deployment:
#
#   sudo SECARMA_ORG_TOKEN=sec_xxxxxxxx ./install.sh
#   curl -fsSL https://raw.githubusercontent.com/Secarma-act/secarma-agent/refs/heads/main/packaging/linux/install.sh | sudo SECARMA_ORG_TOKEN=sec_xxx bash
#
# Required env:
#   SECARMA_ORG_TOKEN   the account org-token (starts "sec_"). Never logged.
#
# Optional env:
#   SECARMA_SERVER_URL     platform base URL          (default: https://mon-api.secarma.com)
#   SECARMA_VERSION        pin a version, e.g. 0.1.0  (default: latest, from VERSION.md)
#   SECARMA_BINARY_URL     fully override the download (default: derived from version + arch)
#   SECARMA_BINARY_SHA256  expected sha256 of the binary (verified when set)
#
set -euo pipefail

SERVER_URL="${SECARMA_SERVER_URL:-https://mon-api.secarma.com}"
REPO="Secarma-act/secarma-agent"
VERSION_URL="https://raw.githubusercontent.com/${REPO}/refs/heads/main/VERSION.md"

# The binary lives in a dedicated, service-writable directory (not /usr/bin) so the
# agent can replace itself for self-update while ProtectSystem=strict keeps the rest of
# the filesystem read-only.
BIN_DIR="/opt/secarma-agent"
BIN_PATH="$BIN_DIR/secarma-agent"
CONFIG_DIR="/etc/secarma-agent"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_DIR="/var/lib/secarma-agent"
UNIT_FILE="/etc/systemd/system/secarma-agent.service"

log() { printf '[secarma-install] %s\n' "$*"; }
die() { printf '[secarma-install] ERROR: %s\n' "$*" >&2; exit 1; }

# --- Preconditions --------------------------------------------------------------
[ "$(id -u)" -eq 0 ]            || die "must run as root (use sudo)."
[ "$(uname -s)" = "Linux" ]     || die "this installer is for Linux only."
command -v systemctl >/dev/null || die "systemd (systemctl) is required."
command -v curl >/dev/null      || die "curl is required."
[ -n "${SECARMA_ORG_TOKEN:-}" ] || die "SECARMA_ORG_TOKEN is required."
case "$SECARMA_ORG_TOKEN" in
  sec_*) ;;
  *) die "SECARMA_ORG_TOKEN does not look like an org-token (expected it to start with 'sec_')." ;;
esac

# --- Architecture ---------------------------------------------------------------
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/secarma-agent"

# --- Resolve version + download URL ---------------------------------------------
version="${SECARMA_VERSION:-}"
if [ -z "$version" ]; then
  log "resolving latest version…"
  version="$(curl -fsSL --retry 3 --retry-delay 2 "$VERSION_URL" 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || true
  [ -n "$version" ] || die "could not determine the latest version from $VERSION_URL"
fi
log "version: $version, arch: $arch"

bin_url="${SECARMA_BINARY_URL:-https://github.com/${REPO}/releases/download/v${version}/secarma-agent-${version}-linux-${arch}}"

# --- Download + verify ----------------------------------------------------------
log "downloading $bin_url"
curl -fsSL --retry 3 --retry-delay 2 "$bin_url" -o "$bin" || die "download failed from $bin_url"

if [ -n "${SECARMA_BINARY_SHA256:-}" ]; then
  actual="$(sha256sum "$bin" | awk '{print $1}')"
  [ "$actual" = "$SECARMA_BINARY_SHA256" ] || die "checksum mismatch (got $actual)."
  log "checksum verified."
fi

# --- Install binary -------------------------------------------------------------
install -D -m 0755 "$bin" "$BIN_PATH"

# --- Write config ---------------------------------------------------------------
log "writing config to $CONFIG_FILE"
mkdir -p "$CONFIG_DIR" "$STATE_DIR"
umask 077
cat > "$CONFIG_FILE" <<EOF
{
  "server_url": "$SERVER_URL",
  "org_token": "$SECARMA_ORG_TOKEN",
  "credentials_file": "$STATE_DIR/agent-credentials.json",
  "signature_cache": "$STATE_DIR/agent-signatures.json",
  "buffer": { "dir": "$STATE_DIR/buffer" },
  "log": { "file": "$STATE_DIR/secarma-agent.log" },
  "update": { "enabled": true, "state_file": "$STATE_DIR/agent-update.json" }
}
EOF
chmod 600 "$CONFIG_FILE"

# --- Install systemd unit -------------------------------------------------------
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Secarma Security Agent
Documentation=https://secarma.com
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_PATH -config $CONFIG_FILE
Restart=always
RestartSec=10
StateDirectory=secarma-agent
# State dir + the binary dir are writable so the agent can buffer, cache, and
# self-update; everything else stays read-only under ProtectSystem=strict.
ReadWritePaths=$STATE_DIR $BIN_DIR
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# --- Enable + start -------------------------------------------------------------
log "enabling and starting the service…"
systemctl daemon-reload
systemctl enable secarma-agent.service >/dev/null 2>&1 || true
systemctl restart secarma-agent.service

if systemctl is-active --quiet secarma-agent.service; then
  log "installed — the agent is running and will enrol on first collection."
else
  log "installed, but the service isn't active. Check: journalctl -u secarma-agent -n 50"
fi
