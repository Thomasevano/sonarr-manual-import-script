# Sonarr Manual Import Script

> [!NOTE]
> This project is inspired by [SonarrAutoImport](https://github.com/Webreaper/SonarrAutoImport)

## Installation

### Prerequisites

- Debian/Ubuntu-based system with systemd
- `jq` and `curl` installed (`apt-get install jq curl`)

### Setup

1. Clone the repo on your server:

```bash
git clone https://github.com/Thomasevano/sonarr-manual-import-script.git
cd sonarr-manual-import-script
```

2. Configure `settings.json` with your values:

```json
{
  "sonarr": {
    "url": "http://localhost:8989",
    "apiKey": "your-api-key",
    "downloadsFolder": "/path/to/downloads",
    "mappingPath": "/path/to/downloads/in/sonarr/container",
    "importMode": "Move",
    "timeoutSecs": "5"
  }
}
```

- **downloadsFolder:** path to the downloads folder on your server
- **mappingPath:** path to the downloads folder as seen by Sonarr (inside Docker container if applicable)

3. Run the install script:

```bash
sudo ./install.sh
```

This will:
- Copy files to `/opt/sonarr-manual-import/`
- Create and enable systemd units to watch your downloads folder
- Automatically trigger imports when new files appear

### Useful Commands

```bash
# Check if the watcher is running
systemctl status sonarr-import.path

# View import logs
journalctl -u sonarr-import.service -f

# Manually trigger an import
systemctl start sonarr-import.service

# Stop watching for new files
systemctl stop sonarr-import.path

# Completely disable auto-import
systemctl disable sonarr-import.path
```

### Uninstall

```bash
sudo ./uninstall.sh
```

## Manual Usage

You can also run the script manually:

```bash
./batchimport.sh -c settings.json
./batchimport.sh --verbose --dry-run  # Test without making changes
```

## Features

- [x] Scan the folder and imports files one by one
- [x] Rename files via configurable transforms
- [x] Delete empty leftover folders
- [x] Automatic import when files appear (systemd path watcher)
