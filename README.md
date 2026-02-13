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
    "timeoutSecs": "5",
    "transforms": [],
    "seriesMappings": []
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
./batchimport.sh --list-series        # List all series with their IDs
```

## Import Flow

The script automatically handles files that Sonarr can't recognize:

```
┌─────────────────────────────────────────────────────────────┐
│  1. Check if file matches a seriesMapping                   │
│     ├── YES → Use ManualImport API (fast, reliable)         │
│     └── NO  → Continue to step 2                            │
├─────────────────────────────────────────────────────────────┤
│  2. Try to auto-match series name from filename             │
│     ├── MATCH → Use ManualImport API + save mapping         │
│     └── NO MATCH → Continue to step 3                       │
├─────────────────────────────────────────────────────────────┤
│  3. Fall back to standard Sonarr scan                       │
│     └── Let Sonarr handle the file normally                 │
└─────────────────────────────────────────────────────────────┘
```

### Example

For a file named `Las.Vegas.TRUEFRENCH.S02E03.DVDRIP.AC3.x264-Darkjedi.mkv`:

**First run:**
```bash
./batchimport.sh
# 1. No seriesMapping found
# 2. Auto-matches "Las Vegas" to your library (95% match)
# 3. Imports using ManualImport API
# 4. Saves mapping to settings.json for future use
```

**Future runs:**
```bash
./batchimport.sh
# 1. seriesMapping exists for "Las.Vegas" → imports directly via ManualImport API
```

### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `autoMatch` | `true` | Enable/disable automatic series matching |
| `autoMatchMinScore` | `70` | Minimum similarity score (0-100) required for a match |

```json
{
  "sonarr": {
    "autoMatch": true,
    "autoMatchMinScore": 70
  }
}
```

### Automatic Mapping Persistence

When the script successfully auto-matches a series, it **automatically saves the mapping** to your `settings.json` file. This means:

1. **First episode**: Script extracts "Las Vegas" from filename, fuzzy matches to your library, finds the series, and **saves the mapping**
2. **Future episodes**: The mapping already exists in `seriesMappings`, so no fuzzy matching needed - instant recognition!

Example: After auto-matching `Las.Vegas.S02E03.mkv`, your settings.json will automatically be updated:

```json
{
  "sonarr": {
    "seriesMappings": [
      {
        "pattern": "Las[. ]Vegas",
        "seriesId": 123,
        "comment": "Las Vegas (auto-matched)"
      }
    ]
  }
}
```

You can edit these mappings manually if needed, or delete them to force re-matching.

### When Auto-Match Fails

If auto-matching doesn't work for a specific series (e.g., the filename is too different from the series title), you can add a manual mapping:

```json
{
  "sonarr": {
    "seriesMappings": [
      {
        "pattern": "CSI\\.NY",
        "seriesId": 123,
        "comment": "CSI: NY - colon in title causes issues"
      }
    ]
  }
}
```

To find the series ID:
```bash
./batchimport.sh --list-series | grep -i "csi"
```

### Manual Mapping Configuration

| Field | Required | Description |
|-------|----------|-------------|
| `pattern` | Yes | Regex pattern to match in the filename (case-insensitive) |
| `seriesId` | Yes | The Sonarr internal series ID (use `--list-series` to find it) |
| `comment` | No | Human-readable description for your reference |

### Supported Episode Formats

The script automatically parses these episode formats:

- `S01E01` - Standard format
- `S01E01E02` - Multi-episode (consecutive)
- `S01E01-E03` - Multi-episode (range)
- `1x01` - Alternative format

### Quality Detection

Quality is automatically detected from the filename:

| Pattern | Detected Quality |
|---------|------------------|
| `DVDRIP`, `DVD-RIP` | DVD |
| `HDTV`, `720p` | HDTV-720p |
| `HDTV`, `1080p` | HDTV-1080p |
| `WEBDL`, `WEB-DL` | WEBDL-1080p (or 720p if specified) |
| `WEBRIP`, `WEB-RIP` | WEBRip-720p (or 1080p if specified) |
| `BLURAY` | Bluray-1080p (or 720p if specified) |
| `2160p`, `4K`, `UHD` | WEBDL-2160p |

### Language Detection

Language is automatically detected from common tags:

- `FRENCH`, `TRUEFRENCH`, `VFF` → French
- `GERMAN`, `DEUTSCH` → German
- `SPANISH`, `ESPANOL` → Spanish
- etc.

## Features

- [x] Scan the folder and imports files one by one
- [x] Rename files via configurable transforms
- [x] Delete empty leftover folders
- [x] Automatic import when files appear (systemd path watcher)
- [x] **Automatic series matching** - fuzzy matches filenames to your Sonarr library
- [x] Manual series mappings for edge cases
- [x] Multi-episode file support (S01E01E02, S01E01-E03)
- [x] Automatic quality detection (DVD, HDTV, WEB-DL, Bluray, 4K)
- [x] Automatic language detection (French, German, Spanish, etc.)
- [x] Dry-run mode for testing
- [x] List series helper command
