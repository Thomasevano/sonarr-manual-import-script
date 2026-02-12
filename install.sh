#!/usr/bin/env bash

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="/opt/sonarr-manual-import"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check dependencies
for cmd in jq curl; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Missing dependency: $cmd"
        log_error "Install with: apt-get install $cmd"
        exit 1
    fi
done

# Check for settings.json
if [[ ! -f "$SCRIPT_DIR/settings.json" ]]; then
    log_error "settings.json not found in $SCRIPT_DIR"
    log_error "Please create settings.json with your Sonarr configuration first"
    exit 1
fi

# Read downloads folder from settings
DOWNLOADS_FOLDER=$(jq -r '.sonarr.downloadsFolder' "$SCRIPT_DIR/settings.json")

if [[ -z "$DOWNLOADS_FOLDER" ]] || [[ "$DOWNLOADS_FOLDER" == "null" ]] || [[ "$DOWNLOADS_FOLDER" == "/path/to/downloads" ]]; then
    log_error "Invalid or unconfigured downloadsFolder in settings.json"
    log_error "Please set the correct path before installing"
    exit 1
fi

if [[ ! -d "$DOWNLOADS_FOLDER" ]]; then
    log_warn "Downloads folder does not exist: $DOWNLOADS_FOLDER"
    log_warn "Make sure it exists before the service starts"
fi

log "Installing sonarr-manual-import..."
log "  Install directory: $INSTALL_DIR"
log "  Watch folder: $DOWNLOADS_FOLDER"

# Create install directory
mkdir -p "$INSTALL_DIR"

# Copy files
cp "$SCRIPT_DIR/batchimport.sh" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/settings.json" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/batchimport.sh"

# Create systemd path unit with correct path
cat > /etc/systemd/system/sonarr-import.path <<EOF
[Unit]
Description=Watch downloads folder for new TV show episodes
Documentation=https://github.com/thomasevano/sonarr-manual-import

[Path]
PathChanged=$DOWNLOADS_FOLDER
# Debounce: wait for file writes to settle
TriggerLimitIntervalSec=10
TriggerLimitBurst=1

[Install]
WantedBy=multi-user.target
EOF

# Create systemd service unit
cat > /etc/systemd/system/sonarr-import.service <<EOF
[Unit]
Description=Import TV show episodes to Sonarr
Documentation=https://github.com/thomasevano/sonarr-manual-import

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/batchimport.sh -c $INSTALL_DIR/settings.json
# Wait for files to finish copying
ExecStartPre=/bin/sleep 5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sonarr-import

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable
systemctl daemon-reload
systemctl enable sonarr-import.path
systemctl start sonarr-import.path

log ""
log "Installation complete!"
log ""
log "The service is now watching: $DOWNLOADS_FOLDER"
log ""
log "Useful commands:"
log "  Check status:    systemctl status sonarr-import.path"
log "  View logs:       journalctl -u sonarr-import.service -f"
log "  Manual trigger:  systemctl start sonarr-import.service"
log "  Stop watching:   systemctl stop sonarr-import.path"
log "  Disable:         systemctl disable sonarr-import.path"
log ""
log "Config file location: $INSTALL_DIR/settings.json"
