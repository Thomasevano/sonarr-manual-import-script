#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
VERBOSE=false
DRY_RUN=false
CONFIG_FILE="settings.json"

# Video file extensions
VIDEO_EXTENSIONS=("mkv" "avi" "wmv" "mov" "amv" "mp4" "m4v" "f4v" "mpg" "mp2" "mpeg" "mpe" "mpv")

##############################################################################
# Functions
##############################################################################

log() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

log_error() {
  echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == true ]]; then
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] VERBOSE:${NC} $*"
  fi
}

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Scan video files and submit them to import into Sonarr

OPTIONS:
    -c, --config FILE    Path to settings JSON file (default: settings.json)
    -v, --verbose        Enable verbose logging
    -d, --dry-run        Dry run - scan files but don't call Sonarr API
    -h, --help          Show this help message

EXAMPLES:
    $0 -c /path/to/settings.json
    $0 --verbose --dry-run
    $0 -c settings.json -v

CONFIGURATION FILE:
    The configuration file should be in JSON format with the following structure:
    {
      "sonarr": {
        "url": "http://localhost:8989",
        "apiKey": "your-api-key",
        "mappingPath": "/downloads/",
        "downloadsFolder": "/path/to/downloads",
        "importMode": "Copy",
        "timeoutSecs": 5,
        "trimFolders": true,
        "transforms": [
          {
            "search": "Series (\\\\d+) - ",
            "replace": "S\\\\1E"
          }
        ]
      }
    }

EOF
  exit 0
}

check_dependencies() {
  local missing_deps=()

  if ! command -v jq &>/dev/null; then
    missing_deps+=("jq")
  fi

  if ! command -v curl &>/dev/null; then
    missing_deps+=("curl")
  fi

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    log_error "Missing required dependencies: ${missing_deps[*]}"
    log_error "Please install them before running this script."
    log_error "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
    log_error "  MacOS: brew install ${missing_deps[*]}"
    exit 1
  fi
}

is_video_file() {
  local file="$1"
  local ext="${file##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  for valid_ext in "${VIDEO_EXTENSIONS[@]}"; do
    if [[ "$ext" == "$valid_ext" ]]; then
      return 0
    fi
  done
  return 1
}

apply_transforms() {
  local filename="$1"
  local transforms_json="$2"
  local new_filename="$filename"

  if [[ -z "$transforms_json" ]] || [[ "$transforms_json" == "null" ]]; then
    log_verbose "No transforms configured"
    return 0
  fi

  local transform_count=$(echo "$transforms_json" | jq 'length')
  log_verbose "Applying $transform_count transform(s) to: $filename"

  for ((i = 0; i < transform_count; i++)); do
    local search=$(echo "$transforms_json" | jq -r ".[$i].search")
    local replace=$(echo "$transforms_json" | jq -r ".[$i].replace")

    # Apply regex transform using sed
    new_filename=$(echo "$new_filename" | sed -E "s/$search/$replace/gI")
    log_verbose "  Transform $((i + 1)): $search -> $replace"
  done

  if [[ "$filename" != "$new_filename" ]]; then
    log "Filename transformed: $filename => $new_filename"
  fi

  echo "$new_filename"
}

rename_file() {
  local old_path="$1"
  local new_filename="$2"
  local dir=$(dirname "$old_path")
  local old_filename=$(basename "$old_path")

  if [[ "$old_filename" == "$new_filename" ]]; then
    echo "$old_path"
    return 0
  fi

  local new_path="$dir/$new_filename"

  log "Renaming file: $old_filename -> $new_filename"

  if mv "$old_path" "$new_path" 2>/dev/null; then
    echo "$new_path"
    return 0
  else
    log_error "Failed to rename file: $old_path"
    echo "$old_path"
    return 1
  fi
}

translate_path() {
  local base_folder="$1"
  local full_path="$2"
  local mapping_path="$3"

  # Remove base folder from full path
  local relative_path="${full_path#$base_folder}"
  relative_path="${relative_path#/}"

  # Combine with mapping path
  local mapped_path="${mapping_path%/}/$relative_path"

  echo "$mapped_path"
}

call_sonarr_api() {
  local url="$1"
  local api_key="$2"
  local remote_path="$3"
  local import_mode="$4"

  local payload=$(jq -n \
    --arg path "$remote_path" \
    --arg mode "$import_mode" \
    '{
            name: "DownloadedEpisodesScan",
            path: $path,
            importMode: $mode,
            downloadClientId: "SonarrAutoImporter"
        }')

  log_verbose "API Payload: $payload"

  local response=$(curl -s -w "\n%{http_code}" -X POST \
    "${url}/api/v3/command" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${api_key}" \
    -H "User-Agent: SonarrAutoImport-Bash" \
    -d "$payload")

  local http_code=$(echo "$response" | tail -n1)
  local response_body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 200 ]] && [[ "$http_code" -lt 300 ]]; then
    log " - Executed Sonarr command for: $remote_path"
    if [[ "$VERBOSE" == true ]]; then
      echo "$response_body" | jq '.' 2>/dev/null || echo "$response_body"
    fi
    return 0
  else
    log_error "API request failed with status $http_code"
    log_error "Response: $response_body"
    return 1
  fi
}

process_sonarr() {
  local config="$1"

  # Read configuration
  local url=$(echo "$config" | jq -r '.url')
  local api_key=$(echo "$config" | jq -r '.apiKey')
  local mapping_path=$(echo "$config" | jq -r '.mappingPath')
  local downloads_folder=$(echo "$config" | jq -r '.downloadsFolder')
  local import_mode=$(echo "$config" | jq -r '.importMode // "Move"')
  local timeout_secs=$(echo "$config" | jq -r '.timeoutSecs // 5')
  local trim_folders=$(echo "$config" | jq -r '.trimFolders // false')
  local transforms=$(echo "$config" | jq -c '.transforms // []')

  # Validate import mode
  if [[ "$import_mode" != "Copy" ]] && [[ "$import_mode" != "Move" ]]; then
    log_error "Invalid importMode '$import_mode' in settings. Defaulting to 'Move'"
    import_mode="Move"
  fi

  log "Starting video processing for: $downloads_folder"

  if [[ "$VERBOSE" == true ]]; then
    log " Base URL:     $url"
    log " API Key:      ${api_key:0:8}..."
    log " Mapping:      $mapping_path"
    log " Timeout:      $timeout_secs"
    log " Import Mode:  $import_mode"
    log " Trim Folders: $trim_folders"
    log " Dry Run:      $DRY_RUN"
  fi

  # Check if directory exists
  if [[ ! -d "$downloads_folder" ]]; then
    log_error "Folder $downloads_folder was not found. Check configuration."
    return 1
  fi

  # Find all video files
  local video_files=()
  while IFS= read -r -d '' file; do
    if is_video_file "$file"; then
      video_files+=("$file")
    fi
  done < <(find "$downloads_folder" -type f -print0)

  if [[ ${#video_files[@]} -eq 0 ]]; then
    log "No videos found. Nothing to do!"
    return 0
  fi

  log "Processing ${#video_files[@]} video file(s)..."

  local success=true

  for video_file in "${video_files[@]}"; do
    local filename=$(basename "$video_file")
    local new_filename=$(apply_transforms "$filename" "$transforms")
    local video_path="$video_file"

    # Rename file if transforms were applied
    if [[ "$filename" != "$new_filename" ]] && [[ "$DRY_RUN" == false ]]; then
      video_path=$(rename_file "$video_file" "$new_filename")
    fi

    # Translate path for Sonarr
    local remote_path=$(translate_path "$downloads_folder" "$video_path" "$mapping_path")

    if [[ "$DRY_RUN" == true ]]; then
      log " => $remote_path"
    else
      if ! call_sonarr_api "$url" "$api_key" "$remote_path" "$import_mode"; then
        success=false
      fi
    fi

    # Sleep between files if configured
    if [[ "$timeout_secs" -gt 0 ]] && [[ "$DRY_RUN" == false ]]; then
      log_verbose "Sleeping for $timeout_secs seconds..."
      sleep "$timeout_secs"
    fi
  done

  if [[ "$success" == true ]]; then
    log "All processing completed successfully."
  else
    log "Processing completed with errors."
  fi
}

##############################################################################
# Main
##############################################################################

main() {
  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
    -c | --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    -v | --verbose)
      VERBOSE=true
      shift
      ;;
    -d | --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      usage
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      ;;
    esac
  done

  # Check dependencies
  check_dependencies

  # Check if config file exists
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Configuration file not found: $CONFIG_FILE"
    exit 1
  fi

  log "Reading configuration from: $CONFIG_FILE"

  # Read and validate JSON
  if ! config_json=$(jq '.' "$CONFIG_FILE" 2>&1); then
    log_error "Invalid JSON in configuration file: $config_json"
    exit 1
  fi

  # Extract Sonarr configuration
  sonarr_config=$(echo "$config_json" | jq '.sonarr')

  if [[ "$sonarr_config" == "null" ]]; then
    log_error "No Sonarr configuration found in $CONFIG_FILE"
    exit 1
  fi

  # Process Sonarr
  log "Processing videos for Sonarr..."
  process_sonarr "$sonarr_config"

  log "Done!"
}

# Run main function
main "$@"
