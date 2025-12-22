# Sonarr Manual Import Script

> [!NOTE]
> This project is inspired by [SonarrAutoImport](https://github.com/Webreaper/SonarrAutoImport)

## Installation

Clone the repo on your server

```bash
git clone https://github.com/Thomasevano/sonarr-manual-import-script.git
cd sonarr-manual-import-script
chmod +x batchimport.sh
```

## Usage

> [!IMPORTANT]
> jq and curl is needed to launch the Script

Configure `settings.json` with your own values

- **downloaderFolder:** path to downloaderFolder on your server from script location
- **mappingPath:** path to downloaderFolder inside sonarr docker container

Then run the script

```bash
./batchimport.sh
```

## Features

- [x] Scan the folder and imports files one by one
- [x] Rename files
- [x] Delete empty left folders
- [ ] Check when the **downloaderFolder** is modified and launch the script
