#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

INSTALL_DIR="/opt/sonarr-manual-import"

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

log "Uninstalling sonarr-manual-import..."

# Stop and disable services
systemctl stop sonarr-import.path 2>/dev/null || true
systemctl stop sonarr-import.service 2>/dev/null || true
systemctl disable sonarr-import.path 2>/dev/null || true

# Remove systemd units
rm -f /etc/systemd/system/sonarr-import.path
rm -f /etc/systemd/system/sonarr-import.service
systemctl daemon-reload

# Remove install directory
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    log "Removed $INSTALL_DIR"
fi

log "Uninstallation complete!"
